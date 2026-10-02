import AppKit
import Foundation
import SwiftUI
import Testing
import MacAudio
@testable import LiveLearnApp

/// Round 12 foundation: the shared primitives other surfaces build on (StarMark, FadingRule,
/// the compact capsule, the paper menu's grid, the active editor's draft marks). Geometry and
/// parity are pinned here; how they look is reviewed from renders (`gallery`, opt-in).
@MainActor
struct Round12FoundationTests {
    /// The host's star and the helper-shared settings star are one substance: in the dark with
    /// no tint they must be the same pixels, so a chosen menu row and a chosen settings word are
    /// marked by the same point of light. (`StarMark` wraps `SettingsStarPoint`; this pins that
    /// it keeps doing so.)
    @Test func starMarkIsTheSettingsStarPointInTheDark() throws {
        func render(_ view: some View, contrast: ColorSchemeContrast) throws -> CGImage {
            try renderedImage(ThemedRoot(forced: .stellar) { view }
                .environment(\._colorSchemeContrast, contrast)
                .padding(4).background(Color(hex: 0x101114)), scale: 4)
        }
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let host = try render(StarMark(), contrast: contrast)
            let shared = try render(SettingsStarPoint(dark: true), contrast: contrast)
            let diff = try pixelDiff(host, shared)
            #expect(diff.isUnchanged, "\(contrast): \(diff)")
            // Not two empty canvases: the core is drawn (brightest red sample, alpha skipped).
            let samples = try canonicalSamples(host)
            #expect(stride(from: 0, to: samples.count, by: 4).map { samples[$0] }.max() ?? 0 > 180)
        }
    }

    /// A class hue is the shared star's own coverage painted in the hue, in the slot and stamped
    /// under a word — not a second recipe: the same alpha as `SettingsStarPoint` at every pixel
    /// (within `RenderDiff.isUnchanged`'s levels: the mask's offscreen pass lands the core's
    /// anti-aliased rim 8 levels apart at 4×), the hue's colour wherever the point is solid.
    /// Under Increase Contrast the hue is dropped for the plain `ink` point every star becomes
    /// there.
    @Test func tintedStarMarkIsTheSharedStarInTheHue() throws {
        let gold = Color(hex: 0xD8B98B)
        func samples(_ view: some View, contrast: ColorSchemeContrast = .standard) throws -> [UInt8] {
            // 12 pt of room on every side holds a stamped point, drawn 9 pt under its slot.
            try canonicalSamples(renderedImage(ThemedRoot(forced: .stellar) { view.padding(12) }
                .environment(\._colorSchemeContrast, contrast), scale: 4))
        }
        for stamped in [false, true] {
            let tinted = try samples(StarMark(placement: stamped ? .under : .slot, tint: gold))
            let shared = try samples(SettingsStarPoint(dark: true, stamped: stamped))
            try #require(tinted.count == shared.count)
            var alphaTotal = 0, alphaWorst = 0, hueWorst = 0, solid = 0
            for p in stride(from: 0, to: tinted.count, by: 4) {
                let alpha = Int(tinted[p + 3])
                let delta = abs(alpha - Int(shared[p + 3]))
                alphaTotal += delta
                alphaWorst = max(alphaWorst, delta)
                guard alpha >= 128 else { continue }
                solid += 1
                for (c, hue) in [0xD8, 0xB9, 0x8B].enumerated() {
                    hueWorst = max(hueWorst, abs(Int(tinted[p + c]) * 255 / alpha - hue))
                }
            }
            let alphaMean = Double(alphaTotal) / Double(tinted.count / 4)
            #expect(alphaMean < 0.5 && alphaWorst <= 8 && hueWorst <= 6 && solid > 0,
                    "stamped \(stamped): alpha mean \(alphaMean) max \(alphaWorst), hue Δ\(hueWorst), \(solid) solid px")
        }
        let increased = try samples(StarMark(tint: gold), contrast: .increased)
        #expect(try increased == samples(SettingsStarPoint(dark: true), contrast: .increased))
    }

    /// The source check's details box is as tall as its lines up to the 100 pt cap, then holds
    /// there (the lines scroll inside): no void under two short lines, no window that grows with
    /// a long report.
    @Test func detailsBoxHugsItsLinesUpToTheCap() throws {
        for (lines, expected) in [(CGFloat(38), CGFloat(38)), (160, 100)] {
            let box = HuggingScrollBox(cap: 100) {
                Color.clear.frame(height: lines)
                Color.black
            }
            let image = try renderedImage(box.frame(width: 120).environment(\.staticRender, true), scale: 1)
            #expect(CGFloat(image.height) == expected, "\(lines) pt of lines")
        }
        // A max-size probe (an unbounded width) gets the lines' own width back: a layout that
        // reported infinity would leave nothing to render.
        let probe = ImageRenderer(content: HuggingScrollBox(cap: 100) {
            Color.clear.frame(width: 90, height: 38)
            Color.black
        }.environment(\.staticRender, true))
        probe.proposedSize = ProposedViewSize(width: .infinity, height: nil)
        let image = try #require(probe.cgImage)
        #expect(image.width == 90 && image.height == 38)
    }

    @Test func fadingRuleStopsFadeTheRightEnds() {
        let settings = FadingRule.stops(length: 400, ends: .trailing, fade: nil)
        #expect(settings.map(\.location) == [0, 0.9, 1] && settings.map(\.opaque) == [true, true, false])
        let column = FadingRule.stops(length: 240, ends: .both, fade: 24)
        #expect(column.map(\.location) == [0, 0.1, 0.9, 1] && column.map(\.opaque) == [false, true, true, false])
        // A named fade longer than half a short rule peaks in the middle instead of inverting.
        let short = FadingRule.stops(length: 30, ends: .both, fade: 24)
        #expect(short.map(\.location) == [0, 0.5, 0.5, 1])
    }

    /// Every grain lies in the thin band just inside the rim (never out in the air, never over
    /// the label's middle); the dust is composed, not spread — two haloed grains on the upper
    /// shoulders, most of the rest gathered round them, only a short faint run below.
    @Test func capsuleDustClustersInTheBandInsideTheRim() {
        for size in [CGSize(width: 150, height: 32), CGSize(width: 240, height: 32), CGSize(width: 64, height: 32)] {
            let grains = CompactCapsuleGeometry.grains(in: size)
            #expect(grains.count == CompactCapsuleGeometry.count)
            let r = size.height / 2
            let band = CompactCapsuleGeometry.band
            for grain in grains {
                let p = grain.point
                let nearestCentre = CGPoint(x: min(max(p.x, r), size.width - r), y: r)
                let depth = r - hypot(p.x - nearestCentre.x, p.y - nearestCentre.y)
                #expect(depth >= band.lowerBound - 0.01 && depth <= band.upperBound + 0.01, "\(size) \(p)")
            }
            let halos = grains.filter(\.halo)
            #expect(halos.count == 2 && halos.allSatisfy { $0.point.y < r })
            #expect(grains.filter { $0.alpha > 0.3 }.allSatisfy { $0.point.y < r + 0.01 })
            #expect(grains.filter { $0.point.y > r }.count <= CompactCapsuleGeometry.lowerRun)
            let loose = grains.filter { !$0.halo }
            let gathered = loose.filter { grain in
                halos.contains { hypot(grain.point.x - $0.point.x, grain.point.y - $0.point.y) <= CompactCapsuleGeometry.clusterReach }
            }
            #expect(Double(gathered.count) >= 0.6 * Double(loose.count), "\(size): \(gathered.count) of \(loose.count)")
        }
        // On a capsule long enough for a top straight, the halos sit over 14 % and 76 % of it.
        let halos = CompactCapsuleGeometry.grains(in: CGSize(width: 150, height: 32)).filter(\.halo)
        #expect(abs(halos[0].point.x - 21) < 0.5 && abs(halos[1].point.x - 114) < 0.5)
        #expect(halos[0].alpha > halos[1].alpha)
    }

    /// The popover sky stays in the empty band: every star at least 16 pt clear of the title's
    /// words and of the ✕'s 28 pt hit area, in both shells (source 480 pt, language 320 pt).
    @Test func popoverSkyClearsTheTitleAndTheClose() {
        let font = NSFont.systemFont(ofSize: 17, weight: .medium)
        for (title, width) in [("音源与语言", CGFloat(480)), ("翻译方向", 320)] {
            let titleEnd = 24 + (title as NSString).size(withAttributes: [.font: font]).width
            let closeStart = width - 24 - 28
            let stars = PopoverSky.stars(width: width)
            #expect(stars.count == (width < 360 ? 3 : 5))
            for star in stars {
                #expect(star.x - star.diameter / 2 >= titleEnd + 16, "\(title) \(star.x) vs \(titleEnd)")
                #expect(star.x + star.diameter / 2 <= closeStart - 16, "\(title) \(star.x) vs \(closeStart)")
            }
        }
    }

    /// In a paired sheet every slot is a whole 26 pt row, so rows in the two columns stay on one
    /// baseline grid; a lone column keeps its half-row divider.
    @Test func pairedSheetsKeepEverySlotOnTheRowGrid() {
        let row = PaperMenuSheet.rowHeight
        for kind in [PaperMenuItem.Kind.row, .check, .section, .divider] {
            #expect(PaperMenuSheet.slotHeight(kind, paired: true) == row)
        }
        #expect(PaperMenuSheet.slotHeight(.divider, paired: false) == row / 2)
        #expect(PaperMenuSheet.slotHeight(.section, paired: false) == row)
    }

    @Test func draftMarksOnlyWhatTheRestartWouldChange() {
        let suite = "LiveLearn.testing.draft-marks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot(dual: true))
        let live = SessionSourceSelection(model: model)
        let untouched = DraftChanges(draft: live, live: live)
        #expect(!untouched.computerChannel && !untouched.computerSource && !untouched.listenDirection
                && !untouched.microphoneChannel && !untouched.microphone && !untouched.micDirection)

        var draft = live
        draft.languages.listenTarget = draft.languages.listenTarget == "ja" ? "ko" : "ja"
        var changes = DraftChanges(draft: draft, live: live)
        #expect(changes.listenDirection && !changes.micDirection && !changes.computerSource)

        // A list kept behind 全部应用 changes nothing the capture would do.
        draft = live
        draft.computer = .system
        let app = RunningApplicationSummary(bundleIdentifier: "test.app", name: "Test", path: nil, pid: 0, isPlayingAudio: false)
        draft.applications = [app]
        var systemLive = live
        systemLive.computer = .system
        systemLive.applications = []
        changes = DraftChanges(draft: draft, live: systemLive)
        #expect(!changes.computerSource && !changes.computerChannel)

        draft.computer = .off
        changes = DraftChanges(draft: draft, live: systemLive)
        #expect(changes.computerChannel && changes.computerSource)

        draft = live
        draft.microphoneEnabled.toggle()
        changes = DraftChanges(draft: draft, live: live)
        #expect(changes.microphoneChannel && !changes.microphone)
    }

    /// Opt-in review renders of the primitives and the surfaces without a fixture of their
    /// own: `LIVELEARN_R12_GALLERY=<dir> swift test --filter Round12FoundationTests/gallery`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_R12_GALLERY"] != nil))
    func gallery() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_R12_GALLERY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ view: some View, _ name: String, theme: LLTheme, contrast: ColorSchemeContrast = .standard,
                  size: CGSize? = nil, scale: CGFloat = 2) throws {
            let root = ThemedRoot(forced: theme) { view }
                .environment(\._colorSchemeContrast, contrast)
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
                .environment(\.staticRender, true)
                .frame(width: size?.width, height: size?.height)
            let image = try renderedImage(root, scale: scale)
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        for theme in [LLTheme.stellar, .wilds] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let suffix = (theme.isDark ? "dark" : "light") + (contrast == .increased ? "-ic" : "")
                try save(PrimitiveSheet(), "primitives-\(suffix)", theme: theme, contrast: contrast)
                // Ticked and unticked rows must part at 1× as well as at 2×, and under the pointer.
                try save(SourcesSheet(), "menu-sources-\(suffix)", theme: theme, contrast: contrast)
                try save(SourcesSheet(), "menu-sources-\(suffix)-1x", theme: theme, contrast: contrast, scale: 1)
                try save(DictationSheet(), "menu-dictation-\(suffix)", theme: theme, contrast: contrast)
            }
        }
        let suite = "LiveLearn.testing.r12-gallery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let running = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot())
        for theme in [LLTheme.stellar, .wilds] {
            let suffix = theme.isDark ? "dark" : "light"
            try save(MenuBarView().environment(running), "menubar-\(suffix)", theme: theme,
                     size: CGSize(width: LLMetrics.menuWidth, height: 560))
            try save(SourceCheckView().environment(running), "source-check-\(suffix)", theme: theme)
            try save(SourceCheckOutcomes().environment(running), "source-check-outcomes-\(suffix)", theme: theme)
        }
    }
}

/// The finished-check states the window can show (the live report is set only by a real check):
/// audible, failed as it opens (details closed), failed with two detail lines open, and a long
/// report whose details reach the box's cap.
private struct SourceCheckOutcomes: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let denied = RecoveryAdvice(title: "需要系统录音权限", detail: "在系统设置里允许 LiveLearn 录制系统声音，然后再检查一次。",
                                    action: .openAudioCaptureSettings)
        let failed = SourceCheck.Report(lines: ["系统声：没有录音权限", "麦克风：未启用"], advice: denied, ok: false)
        let long = SourceCheck.Report(lines: [
            "系统声：48 kHz 立体声 · 150 包，其中 0 包有声音，峰值 0.00 · 3 秒内没有音频 · 没有收到任何音频回调",
            "麦克风：48 kHz 单声道 · 148 包，其中 96 包有声音，峰值 0.41 · 正常",
            "Safari：48 kHz 立体声 · 150 包，全是静音（峰值 0.00）",
            "采集连通，但 Safari 这几秒没有出声；播放内容后再试。",
        ], advice: RecoveryAdvice(title: "麦克风不可用", detail: "所选麦克风已断开。", action: .reselectMicrophone), ok: false)
        VStack(alignment: .leading, spacing: 20) {
            SourceCheckOutcome(report: SourceCheck.Report(lines: ["系统声：峰值 -18 dB", "麦克风：峰值 -31 dB"], advice: nil, ok: true),
                               showDetails: .constant(false))
            FadingRule()
            SourceCheckOutcome(report: failed, showDetails: .constant(false))
            FadingRule()
            SourceCheckOutcome(report: failed, showDetails: .constant(true))
            FadingRule()
            SourceCheckOutcome(report: long, showDetails: .constant(true))
        }
        .padding(24).frame(width: 480, alignment: .leading)
        .background(theme.ground)
    }
}

/// The application check sheet (the preview fixtures draw it on paper only), with the pointer
/// on an unticked row.
private struct SourcesSheet: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let session = PaperMenuSession(columns: {
            [PaperMenuColumn(items: [
                .check("全部应用（系统声）", id: "all", on: false) {},
                .divider(),
                .check("Safari", id: "safari", detail: "正在发声", on: true) {},
                .check("Zoom", id: "zoom", on: true) {},
                .check("Music", id: "music", on: false) {},
                .check("Keynote", id: "keynote", detail: "未运行", on: true) {},
                .divider("refresh"),
                .row("刷新列表", keepsOpen: true) {},
            ])]
        }) { _ in }
        session.highlight = (0, 4)
        return PaperMenuSheet(session: session)
            .frame(width: 320, alignment: .topLeading)
            .background(theme.ground)
    }
}

/// The menu bar's 听写选项 sheet, with 启用完成纠错 on and off: single-choice rows and a check
/// row in one column. Unticked, the check row's ring says it is a toggle; ticked, it wears the
/// same lit star as the chosen language (the lead's star-only tick), so only the unticked state
/// sets it apart from a second choice on sight — VoiceOver says 已勾选 / 未勾选 in both.
private struct DictationSheet: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach([true, false], id: \.self) { correction in
                let session = PaperMenuSession(columns: {
                    [PaperMenuColumn(items: [
                        .section("听写语言"),
                        .row("自动", id: "auto", selected: false) {},
                        .row("中文", id: "zh", selected: true) {},
                        .row("英语", id: "en", selected: false) {},
                        .divider(),
                        .check("启用完成纠错", on: correction) {},
                        .row("纠错设置…") {},
                        .row("设置按住说话快捷键…") {},
                    ])]
                }) { _ in }
                PaperMenuSheet(session: session).frame(width: 300, alignment: .topLeading)
            }
        }
        .background(theme.ground)
    }
}

/// Every primitive in its states on one sheet, for the gallery.
private struct PrimitiveSheet: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                StarMark()
                StarMark(tint: Color(hex: 0xD8B98B))
                Text("星图").font(LLFont.body).foregroundStyle(theme.ink).starMarked(true)
                    .padding(.horizontal, 10).frame(height: 34)
                Text("列表").font(LLFont.body).foregroundStyle(theme.ink2).starMarked(false)
                    .padding(.horizontal, 10).frame(height: 34)
            }
            // Word toggles on and off, and 目录's button form of the same word.
            HStack(spacing: 16) {
                Toggle("字幕", isOn: .constant(true)).toggleStyle(TextToggleStyle()).fixedSize()
                Toggle("锁定", isOn: .constant(false)).toggleStyle(TextToggleStyle()).fixedSize()
                Button("目录") {}.buttonStyle(TextToggleButtonStyle(on: true))
                Button("目录") {}.buttonStyle(TextToggleButtonStyle(on: false))
            }
            // The way forward under a sentence.
            VStack(alignment: .leading, spacing: 12) {
                Text("开始一次会话后，记录会出现在这里。").font(LLFont.body).foregroundStyle(theme.ink2)
                Button("前往首页") {}.buttonStyle(TextButtonStyle(flush: true, strong: true))
            }
            VStack(alignment: .leading, spacing: 12) {
                FadingRule()
                FadingRule(ends: .both, fade: 48)
                HStack { FadingRule(axis: .vertical, ends: .both, fade: 24) }.frame(height: 80)
            }
            BareSearchField(placeholder: "搜索记录", text: .constant(""))
            BareSearchField(placeholder: "搜索记录", text: .constant("Keynote"))
            // The underline at rest, under the pointer and focused (a render cannot focus).
            VStack(spacing: 12) {
                BareSearchField.Underline(focused: false)
                BareSearchField.Underline(focused: false, hovering: true)
                BareSearchField.Underline(focused: true)
            }
            HStack(spacing: 16) {
                Button("应用并重新开始") {}.buttonStyle(CompactCapsuleButtonStyle())
                Button("应用并重新开始") {}.buttonStyle(CompactCapsuleButtonStyle()).disabled(true)
                Button("添加 3 条") {}.buttonStyle(CompactCapsuleButtonStyle())
            }
            HStack(spacing: 20) {
                Toggle("开", isOn: .constant(true)).toggleStyle(QuietSwitchStyle()).labelsHidden()
                Toggle("关", isOn: .constant(false)).toggleStyle(QuietSwitchStyle()).labelsHidden()
                Toggle("禁用", isOn: .constant(true)).toggleStyle(QuietSwitchStyle()).labelsHidden().disabled(true)
                Button {} label: { Image(systemName: "xmark").font(.system(size: 12)) }.buttonStyle(GlyphButtonStyle())
                Button {} label: { Image(systemName: "info.circle").font(.system(size: 13)) }
                    .buttonStyle(GlyphButtonStyle(tint: theme.ink3))
                Button {} label: { Image(systemName: "plus").font(.system(size: 13)) }.buttonStyle(GlyphButtonStyle())
            }
            Text("浮层材质").font(LLFont.body).foregroundStyle(theme.ink2)
                .frame(width: 220, height: 80).floatingPaper()
                .padding(.bottom, 16)
        }
        .padding(28)
        .frame(width: 520, alignment: .leading)
        .background(theme.ground)
    }
}
