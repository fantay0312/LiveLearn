import Foundation
import SwiftUI
import Testing
import ParticleMath
import SessionDomain
@testable import LiveLearnApp

/// Round 12 Home ("One Star Chart"): the one-axis composition and everything that must follow
/// it, the core's material, the paper rule and the quiet inks.
@MainActor
struct Round12HomeTests {
    private let windows = [CGSize(width: 1180, height: 760), CGSize(width: 960, height: 600), CGSize(width: 1440, height: 900)]

    // MARK: Composition

    @Test func homeIsOneUnitOnOneAxisWithTheCapsuleAt44PointsUnderTheCore() {
        let home = HomeComposition(windowWidth: 1180, windowHeight: 760)
        #expect(home == HomeComposition(pageWidth: 1180, pageHeight: 648))
        #expect(home.coreDiameter == 360)
        #expect(abs(home.capsuleTop - (home.coreCenterY + home.coreRadius + 44)) < 1e-9)
        // What is seen — the grains' reach above, the sentence's glyphs below — is centred in
        // the band and lifted 4 pt: the air below is 8 pt more than the air above.
        let above = home.coreCenterY - home.coreRadius
        let below = home.pageHeight - (home.unitBottom - HomeComposition.configurationGlyphInset)
        #expect(abs((below - above) - 2 * HomeComposition.opticalLift) < 1e-9)
        #expect(home.rowTop == home.capsuleTop + 64 && home.configurationTop == home.rowTop + 52)
        #expect(home.windowCoreCenter == CGPoint(x: 590, y: home.coreCenterY + 48))
    }

    @Test func theMinimumWindowKeepsACoreAndRoomForEveryRowItCanGrow() {
        let home = HomeComposition(windowWidth: 960, windowHeight: 600)
        #expect(home.coreDiameter >= 210)
        // A converse route, a failure (title and a one-line detail) and the cloud note fit above
        // the dock (`aRecoveryAndTheCostNoteFitUnderTheUnitAtTheMinimumWindow` measures it).
        #expect(home.pageHeight - home.unitBottom >= 104)
        for height in stride(from: 600.0, through: 1400, by: 10) {
            let h = HomeComposition(windowWidth: 1180, windowHeight: height)
            #expect(HomeComposition.coreRange.contains(h.coreDiameter))
            #expect(h.stageTop >= 0)
            #expect(h.pageHeight - h.unitBottom >= HomeComposition.growthAir - 1e-9)
        }
    }

    @Test func clearanceIsZeroOnWordsAndControlsAndOneInOpenSky() {
        let home = HomeComposition(windowWidth: 1180, windowHeight: 760)
        #expect(home.clearance(x: 300, y: 20) == 0)                                    // header
        #expect(home.clearance(x: 900, y: 740) == 0)                                   // dock
        #expect(home.clearance(x: 590, y: home.windowCapsuleTop + 10) == 0)            // capsule
        #expect(home.clearance(x: 590 + 184 + 8, y: home.windowUnitBottom) == 0)      // beside the column
        #expect(home.clearance(x: 150, y: 300) == 1)                                   // open sky
        #expect(home.clearance(x: 590 + 184 + 28, y: home.windowUnitBottom) == 1)      // 28 pt out
        #expect(home.clearance(x: 300, y: 48 + 20) > 0 && home.clearance(x: 300, y: 48 + 20) < 1)
    }

    /// No glint-magnitude star keeps its glint within 12 pt of a word or control, at any time, in
    /// any window — and some stars do glint, so the rule is not vacuous.
    @Test func starGlintsStayOffTextAndControls() {
        var glints = 0
        for size in windows {
            let home = HomeComposition(windowWidth: size.width, windowHeight: size.height)
            for time in stride(from: 0.0, through: 120, by: 1.5) {
                for index in 0..<290 where StarFieldGeometry.stars[index].bright {
                    let star = StarFieldGeometry.stars[index]
                    let at = StarFieldGeometry.position(index: index, time: time, size: size)
                    let look = StarFieldGeometry.look(star, index: index, at: at, time: time, composition: home)
                    if look.glint != nil {
                        glints += 1
                        #expect(home.clearance(x: at.x, y: at.y) > 0)
                    } else if home.clearance(x: at.x, y: at.y) == 0 {
                        #expect(look.diameter == 1.15)
                    }
                }
            }
        }
        #expect(glints > 100)
    }

    @Test func brightDustKeepsOffWordsAndCarriesNoHaloThere() {
        let field = NebulaFieldGeometry.Field()
        let layout = DustLayout()
        var halos = 0
        for time in [0.0, 2.3, 17, 60] {
            NebulaFieldGeometry.fill(field, time: time)
            layout.layout(field, width: 1180, height: 760, intensity: 1, displace: nil)
            let home = HomeComposition(windowWidth: 1180, windowHeight: 760)
            for j in 0..<layout.count {
                let clear = home.clearance(x: Double(layout.x[j]), y: Double(layout.y[j]))
                #expect(Double(layout.alpha[j]) <= 0.30 + 0.70 * clear + 1e-5)
                if layout.halo[j] {
                    halos += 1
                    #expect(clear >= 1 && layout.alpha[j] > 0.20 && layout.index[j] % 101 == 0)
                }
            }
        }
        #expect(halos > 0)
    }

    /// The dust's two fades sit on the composition: the core's own disc and the control column
    /// are darker than the same field elsewhere.
    @Test func dustFadesFollowTheCoreAndTheControls() {
        let field = NebulaFieldGeometry.Field()
        NebulaFieldGeometry.fill(field, time: 2.3)
        for size in windows {
            let layout = DustLayout()
            layout.layout(field, width: Float(size.width), height: Float(size.height), intensity: 1, displace: nil)
            let home = HomeComposition(windowWidth: size.width, windowHeight: size.height)
            func mean(_ keep: (Double, Double) -> Bool) -> Double {
                let picked = (0..<layout.count).filter { keep(Double(layout.x[$0]), Double(layout.y[$0])) }
                return picked.map { Double(layout.alpha[$0]) }.reduce(0, +) / Double(max(1, picked.count))
            }
            let core = home.windowCoreCenter
            let inCore = mean { hypot($0 - core.x, $1 - core.y) < home.coreRadius * 0.6 }
            let inColumn = mean { abs($0 - home.axisX) < 120 && $1 > home.windowCapsuleTop && $1 < home.windowUnitBottom }
            let open = mean { abs($0 - home.axisX) > 360 && $1 > 90 && $1 < home.dockTop - 40 }
            #expect(inCore < open * 0.6)
            #expect(inColumn < open * 0.6)
        }
    }

    // MARK: Core material

    @Test func theCoreHasThreeMagnitudes() {
        let grains = StardustGeometry.grains(time: 3, activity: 0.12)
        // Radius = magnitude × (0.86 … 1.14): three bands with nothing between them.
        let fine = grains.filter { $0.radius <= 0.00090 * 1.14 + 1e-7 }.count
        let medium = grains.filter { $0.radius >= 0.00148 * 0.86 - 1e-7 && $0.radius <= 0.00148 * 1.14 + 1e-7 }.count
        let bright = grains.filter { $0.radius >= 0.00225 * 0.86 - 1e-7 }.count
        #expect(fine + medium + bright == grains.count)
        let n = Double(grains.count)
        #expect(abs(Double(fine) / n - 0.50) < 0.03 && abs(Double(medium) / n - 0.40) < 0.03 && abs(Double(bright) / n - 0.10) < 0.02)
    }

    /// The rim dissolves: grains thin out past the densest shell instead of piling up at the
    /// edge, and the outermost ones are faint.
    @Test func theRimIsFeatheredNotACircle() {
        let grains = StardustGeometry.grains(time: 3, activity: 0.12)
        let c = StardustGeometry.center
        func band(_ range: Range<Double>) -> [StardustGeometry.Grain] {
            grains.filter { range.contains(hypot($0.point.x - c.x, $0.point.y - c.y)) }
        }
        let body = band(0.27..<0.31), edge = band(0.35..<0.39)
        // Per unit area (annuli widen outward), the edge holds far fewer grains than the body.
        let bodyArea = 0.31 * 0.31 - 0.27 * 0.27, edgeArea = 0.39 * 0.39 - 0.35 * 0.35
        #expect(Double(edge.count) / edgeArea < Double(body.count) / bodyArea * 0.45)
        #expect(!edge.isEmpty)
        let mean = { (g: [StardustGeometry.Grain]) in g.map(\.opacity).reduce(0, +) / Double(max(1, g.count)) }
        #expect(mean(edge) < mean(body) * 0.8)
    }

    /// A volume, not a shell: over its motion the grains light the centre of the projection
    /// about as much as the brightest ring around it (no haze lays light there any more).
    @Test func theCoreCentreIsNotHollow() {
        let c = StardustGeometry.center, reach = 0.345
        var bands = [Double](repeating: 0, count: 6)     // 0.15 of the reach each, out to 0.9
        for time in stride(from: 0.0, to: 6, by: 0.25) {
            for grain in StardustGeometry.grains(time: time, activity: 0.12) {
                let band = Int(hypot(grain.point.x - c.x, grain.point.y - c.y) / reach / 0.15)
                if band < bands.count { bands[band] += grain.opacity * grain.radius * grain.radius }
            }
        }
        // Per unit area: the annulus i spans (i + 1)² − i² = 2i + 1 units. Without the centre's
        // lifted floor it held about two thirds of the brightest ring's light.
        let density = bands.indices.map { bands[$0] / Double(2 * $0 + 1) }
        #expect(density[0] >= 0.8 * density[2...].max()!)
    }

    @Test func runningPausedAndIdleStillsCanBeToldApart() {
        let idle = StardustGeometry.grains(time: 3, activity: 0.12)
        let running = StardustGeometry.grains(time: 3, activity: 0.12, mood: .running)
        let paused = StardustGeometry.grains(time: 3, activity: 0.12, mood: .paused)
        func light(_ grains: [StardustGeometry.Grain], tone: Int? = nil) -> Double {
            grains.filter { tone == nil || $0.tone == tone }.map(\.opacity).reduce(0, +)
        }
        // The ignition is the current's: the lit (pearl) grains gain far more than the far body,
        // which only brightens where it borders the current.
        let lit = light(running, tone: 0) / light(idle, tone: 0), far = light(running, tone: 2) / light(idle, tone: 2)
        #expect(lit > 1.12 && far < lit - 0.08)
        // Paused is held breath, not a faded core: dimmer, but most of idle's light remains.
        #expect(light(paused) < light(idle) * 0.97 && light(paused) > light(idle) * 0.85)
        let dark = StardustPalette(theme: .stellar)
        #expect(dark.tints(silver: 0) == dark.tones && dark.tints(silver: 1) == dark.silver)
        #expect(dark.lit(silver: 1) < dark.lit(silver: 0))
    }

    @Test func theMoodEasesAtTheActivityRate() {
        let motion = StardustMotion()
        _ = motion.sample(time: 0, targetActivity: 1, targetMood: .running)
        let first = motion.sample(time: 1.0 / 30, targetActivity: 0.18, targetMood: .paused)
        #expect(first.mood.silver > 0 && first.mood.silver < 0.2)
        var frame = first
        for index in 2...60 { frame = motion.sample(time: Double(index) / 30, targetActivity: 0.18, targetMood: .paused) }
        #expect(frame.mood.silver > 0.99 && abs(frame.mood.body - 0.94) < 0.01)
    }

    /// Paper takes no light: no lit dust, no glow gradient, forest only on the lit current, and
    /// the body in full ink (depth by size and alpha, not by a paler ink).
    @Test func thePaperPaletteHasNoLitDustAndOneForestTone() {
        let paper = StardustPalette(theme: .wilds)
        #expect(paper.litAlpha == 0 && paper.lit(silver: 0) == 0)
        #expect(paper.tones[0] == AmbientRendering.components(LLTheme.wilds.accent))
        #expect(paper.tones[1] == AmbientRendering.components(LLTheme.wilds.ink))
        #expect(paper.tones[2] == AmbientRendering.components(LLTheme.wilds.ink))
        // The current and the front stand forward by alpha on paper; the sky needs no gain.
        #expect(paper.toneGain[0] > 1 && paper.toneGain[1] > 1 && paper.toneGain[2] == 1)
        #expect(StardustPalette(theme: .stellar).toneGain == SIMD3(1, 1, 1))

        // The encoder applies the gain to the same bins the Canvas does, capped at 1.
        let workspace = StardustGeometry.Workspace()
        StardustGeometry.fill(workspace, time: 1.5, activity: 1)
        let capacity = StardustGeometry.Workspace.pointCapacity()
        let plain = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity), gained = UnsafeMutablePointer<ParticlePoint>.allocate(capacity: capacity)
        defer { plain.deallocate(); gained.deallocate() }
        let (lit, grains) = workspace.encodePoints(into: plain, capacity: capacity, side: 360, scale: 2)
        _ = workspace.encodePoints(into: gained, capacity: capacity, side: 360, scale: 2, toneGain: paper.toneGain)
        for i in lit..<(lit + grains) {
            #expect(gained[i].x == plain[i].x && gained[i].color == plain[i].color)
            #expect(gained[i].alpha == min(1, plain[i].alpha * paper.toneGain[Int(plain[i].color)]))
        }
        // Paused on paper keeps a faded forest current, strictly between forest and ink2.
        let accent = AmbientRendering.components(LLTheme.wilds.accent), ink2 = AmbientRendering.components(LLTheme.wilds.ink2)
        #expect(!paper.silver.contains(accent) && paper.silver[0] != ink2)
        for channel in 0..<3 where accent[channel] != ink2[channel] {
            #expect(min(accent[channel], ink2[channel]) < paper.silver[0][channel]
                    && paper.silver[0][channel] < max(accent[channel], ink2[channel]))
        }
        #expect(StardustPalette(theme: .stellar).litAlpha > 0)
    }

    // MARK: Controls

    @Test func theRailKeepsItsPrimaryOnTheAxis() {
        let capsule = CGSize(width: LuminousActionButton.capsuleWidth, height: 48)
        let stop = CGSize(width: LuminousActionButton.stopWidth, height: 48)
        let alone = AxisRailLayout.arrange([capsule], spacing: 12)
        #expect(alone.frames[0].midX == alone.size.width / 2)
        let session = AxisRailLayout.arrange([capsule, stop], spacing: 12)
        #expect(session.frames[0].midX == session.size.width / 2)
        #expect(session.frames[0].size == capsule)
        #expect(session.frames[1].minX == session.frames[0].maxX + 12 && session.frames[1].maxX == session.size.width)
        #expect(session.size.width == capsule.width + 2 * (12 + stop.width))
    }

    /// The particle layers keep the sky dark around the widest control by a number ParticleMath
    /// holds on its own; it must be the rail's real reach from the axis.
    @Test func theKeepOutColumnIsTheRailsReach() {
        #expect(HomeComposition.controlHalfWidth
                == Double(LuminousActionButton.capsuleWidth / 2 + AxisRailLayout().spacing + LuminousActionButton.stopWidth))
    }

    /// One route is a centred sentence; two share the dot's column, sources flush against it
    /// from the left and directions from the right, the column on the axis when both fit their
    /// half of the band; past the mode row's width the sources give way, but only to a floor.
    @Test func routesHingeOnOneDot() {
        let band = OrbitRow.size.width
        #expect(RouteHingeLayout().maxWidth == band)
        func arrange(_ sizes: [CGSize]) -> (size: CGSize, frames: [CGRect]) {
            RouteHingeLayout.arrange(sizes, spacing: 10, lineHeight: 30, lineSpacing: 4, maxWidth: band)
        }
        let dot = CGSize(width: 4, height: 17)
        // The block is the band; its middle is Home's axis.
        let one = arrange([CGSize(width: 60, height: 30), dot, CGSize(width: 110, height: 30)])
        #expect(one.size == CGSize(width: band, height: 30))
        #expect(one.frames[0].minX == 35 && one.frames[2].maxX == 229)          // the centred sentence

        let two = arrange([CGSize(width: 60, height: 30), dot, CGSize(width: 110, height: 30),
                           CGSize(width: 120, height: 30), dot, CGSize(width: 100, height: 30)])
        #expect(two.size == CGSize(width: band, height: 64))
        #expect(two.frames[1].minX == two.frames[4].minX)                       // one dot column…
        #expect(two.frames[1].midX == band / 2)                                 // …on the axis
        #expect(two.frames[0].maxX == two.frames[3].maxX)                       // sources flush right
        #expect(two.frames[2].minX == two.frames[5].minX)                       // directions flush left
        #expect(two.frames[3].minY == 34 && two.frames[4].midY == 34 + 15)

        // A source wider than its half slides the dot only as far as it needs, truncating nothing.
        let wide = arrange([CGSize(width: 140, height: 30), dot, CGSize(width: 87, height: 30),
                            CGSize(width: 48, height: 30), dot, CGSize(width: 87, height: 30)])
        #expect(wide.frames[1].midX == 152 && min(wide.frames[0].minX, wide.frames[3].minX) == 0)
        #expect(wide.frames[0].width == 140 && wide.frames[2].width == 87)

        let long = arrange([CGSize(width: 200, height: 30), dot, CGSize(width: 110, height: 30)])
        #expect(long.size.width == band && long.frames[2].width == 110 && long.frames[0].width == band - 24 - 110)
        #expect(long.frames[0].minX == 0 && long.frames[2].maxX == band)

        // A long language pair keeps the source readable: whole below the floor, the floor above
        // it, and the direction truncates instead.
        let starved = arrange([CGSize(width: 50, height: 30), dot, CGSize(width: 250, height: 30)])
        #expect(starved.frames[0].width == 50 && starved.frames[2].width == 190)
        let longApp = arrange([CGSize(width: 114, height: 30), dot, CGSize(width: 250, height: 30)])
        #expect(longApp.frames[0].width == 72 && longApp.frames[2].width == 168)
        let converse = arrange([CGSize(width: 50, height: 30), dot, CGSize(width: 90, height: 30),
                                CGSize(width: 55, height: 30), dot, CGSize(width: 220, height: 30)])
        #expect(converse.frames[0].width == 50 && converse.frames[3].width == 55 && converse.frames[5].width == 185)
        #expect(converse.frames[3].minX == 0 && converse.frames[5].maxX == band)
    }

    /// The dock and Home's modes are one row by construction: the geometry the orbit's motion,
    /// its text mask and the routes' cap read is the geometry the rows lay out.
    @Test func theOrbitRowIsOneGeometry() {
        #expect(OrbitRow.size == CGSize(width: 264, height: 44))
        #expect((0..<OrbitRow.cells).map(OrbitRow.centre) == [44, 132, 220])
        for index in 0..<OrbitRow.cells {
            let label = CGPoint(x: OrbitRow.centre(index) / OrbitRow.size.width, y: 0.5)
            #expect(NavigationStarMotion.textVisibility(at: label) < 0.2)
        }
        let row = NSHostingView(rootView: OrbitRowStack {
            ForEach(0..<OrbitRow.cells, id: \.self) { _ in
                Color.clear.frame(width: OrbitRow.cell.width, height: OrbitRow.cell.height)
            }
        })
        #expect(row.fittingSize == OrbitRow.size)
    }

    /// At the minimum window the air under Home's unit holds, under a converse route, the whole
    /// compact banner (`RecoveryBanner`: the title line with its action, a one-line detail) and
    /// the cloud cost note after it — the stack `EmptyStateView.idleControls` lays out.
    @Test func aRecoveryAndTheCostNoteFitUnderTheUnitAtTheMinimumWindow() {
        let defaults = UserDefaults(suiteName: "LiveLearn.testing.r12-home.\(UUID().uuidString)")!
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: .empty())
        func height(_ advice: RecoveryAdvice) -> CGFloat {
            NSHostingView(rootView: RecoveryBanner(advice: advice, compact: true).environment(model).frame(width: 400)).fittingSize.height
        }
        let title = "需要系统音频录制权限", detail = "在 系统设置 › 隐私与安全性 › 录屏与系统录音 中允许 LiveLearn。"
        // The action's target hangs over the title's line: it adds no height.
        #expect(height(RecoveryAdvice(title: title, detail: detail, action: .openAudioCaptureSettings))
                == height(RecoveryAdvice(title: title, detail: detail, action: nil)))
        let line = NSHostingView(rootView: Text(title).font(LLFont.bodyStrong)).fittingSize.height
        let home = HomeComposition(windowWidth: 960, windowHeight: 600)
        let air = home.pageHeight - home.unitBottom
        let route = HomeComposition.configurationHeight + 4
        #expect(air >= route + 12 + line)
        // The failure the previews render: its detail is one line at the banner's 360 pt.
        let banner = height(RecoveryAdvice(title: title, detail: "系统音频录制未获授权。请在系统设置中允许 LiveLearn，然后重新开始。",
                                           action: .openAudioCaptureSettings))
        let note = NSHostingView(rootView: Text("云端处理，可能产生费用").font(LLFont.label)).fittingSize.height
        #expect(air >= route + 12 + banner + 8 + note, "air \(air), needs \(route + 12 + banner + 8 + note)")
    }

    /// The tightest failure — the minimum window, two routes, the cloud engine's cost note — still
    /// says what failed above the dock: the banner's brick title is on the page, whole.
    @Test func aFailureStaysAboveTheDockAtTheMinimumWindow() throws {
        let defaults = UserDefaults(suiteName: "LiveLearn.testing.r12-home-failed.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.recognizer = .deepgram
        var failed = SessionSnapshot.empty()
        failed.state = .failed
        failed.failure = "系统音频录制未获授权。请在系统设置中允许 LiveLearn，然后重新开始。"
        let model = AppModel(settings: settings, preview: failed)
        model.applyMode(.converse)
        #expect(!model.blueprint.isLocal && model.draftLanes.count == 2 && model.recoveryAdvice != nil)

        let size = LLMetrics.minWindow
        let view = ThemedRoot(forced: .wilds) { RootView().environment(model) }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
            .environment(\.staticRender, true)
        let image = try renderedImage(view, scale: 2)
        let samples = try canonicalSamples(image)
        // Brick (#963F31) is the only red on paper; its glyphs' rows at 2×.
        let rows = (0..<image.height).filter { y in
            (0..<image.width).contains { x in
                let i = (y * image.width + x) * 4
                let (r, g, b) = (Int(samples[i]), Int(samples[i + 1]), Int(samples[i + 2]))
                return r - g > 40 && r - b > 40
            }
        }
        let dockTop = Int((size.height - HomeComposition.dockHeight) * 2)
        let top = try #require(rows.first), bottom = try #require(rows.last)
        #expect(bottom < dockTop - 2, "the title's line ends at \(bottom), the dock starts at \(dockTop)")
        #expect(bottom - top >= 16, "a whole line of glyphs, not a clipped sliver")
    }

    /// A single built-in route's dot and the status line's dot meet on one column whether the
    /// session runs or is paused (正在翻译 and the shorter 已暂停); a converse pair on the axis
    /// keeps its clear offset.
    @Test func theStatusDotStandsOnASingleRoutesHinge() {
        let defaults = UserDefaults(suiteName: "LiveLearn.testing.r12-hinge.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let direction = StatusCopy.direction("en", "zh-Hans"), back = StatusCopy.direction("zh-Hans", "en")
        let snap = HingedLines(spacing: HomeComposition.rowToConfiguration).snap
        for state in [SessionState.running, .paused] {
            var snapshot = SampleData.runningSnapshot()
            snapshot.state = state
            let model = AppModel(settings: settings, preview: snapshot)
            func shift(_ routes: [SessionRoutes.Route]) -> CGFloat {
                let dots = DotSink()
                let probe = DotProbe(dots: dots) {
                    SessionStatusLine().frame(height: HomeComposition.rowHeight)
                    SessionRoutes(routes: routes, sourceAction: {}, languageAction: {})
                }
                _ = NSHostingView(rootView: probe.environment(model).frame(width: 400)).fittingSize
                return HingedLines.shift(status: dots.values[0], routes: dots.values[1], snap: snap)
            }
            for source in ["Safari", "系统声"] {
                #expect(shift([.init(source: source, direction: direction)]) != 0, "\(state) · \(source)")
            }
            #expect(shift([.init(source: "Safari", direction: direction), .init(source: "麦克风", direction: back)]) == 0,
                    "\(state) · converse")
        }
    }

    // MARK: Sky off Home

    /// Off Home no star of any magnitude sits on the rails or the vocabulary page's top line, at
    /// any time, in any window; open sky keeps the flat 0.48; Home's composition ignores the rects.
    @Test func starsKeepOffTheRailsOffHome() {
        var cleared = 0, open = 0
        for size in windows {
            for (page, history) in [(MainPage.vocabulary, 0.0), (.transcript, MainWindowLayout.historyWidth(windowWidth: size.width))] {
                let keepOut = RootView.skyKeepOut(on: page, historyWidth: history, window: size)
                #expect(!keepOut.rects.isEmpty)
                for time in stride(from: 0.0, through: 120, by: 3) {
                    for index in 0..<85 {
                        let star = StarFieldGeometry.stars[index]
                        let at = StarFieldGeometry.position(index: index, time: time, size: size)
                        let look = StarFieldGeometry.look(star, index: index, at: at, time: time, composition: nil, keepOut: keepOut)
                        let plain = StarFieldGeometry.look(star, index: index, at: at, time: time, composition: nil)
                        let clearance = keepOut.clearance(x: at.x, y: at.y)
                        if clearance == 0 {
                            cleared += 1
                            #expect(look.opacity == 0)
                        } else if clearance == 1 {
                            open += 1
                            #expect(look.opacity == plain.opacity && look.diameter == plain.diameter)
                        }
                        #expect(look.glint == nil)
                    }
                }
            }
        }
        #expect(cleared > 100 && open > 1000)
        #expect(RootView.skyKeepOut(on: .home, historyWidth: 280, window: windows[0]).rects.isEmpty)
        #expect(RootView.skyKeepOut(on: .transcript, historyWidth: 0, window: windows[0]).rects.isEmpty)

        let home = HomeComposition(windowWidth: 1180, windowHeight: 760)
        let rails = RootView.skyKeepOut(on: .vocabulary, historyWidth: 0, window: windows[0])
        for index in 0..<290 {
            let star = StarFieldGeometry.stars[index]
            let at = StarFieldGeometry.position(index: index, time: 2.3, size: windows[0])
            let a = StarFieldGeometry.look(star, index: index, at: at, time: 2.3, composition: home, keepOut: rails)
            let b = StarFieldGeometry.look(star, index: index, at: at, time: 2.3, composition: home)
            #expect(a.opacity == b.opacity && a.diameter == b.diameter)
        }
    }

    @Test func theStatusClockDropsTheEmptyHour() {
        #expect(StatusCopy.clock(46_000_000_000) == "0:46")
        #expect(StatusCopy.clock(3_599_000_000_000) == "59:59")
        #expect(StatusCopy.clock(3_600_000_000_000) == "1:00:00")
        #expect(StatusCopy.clock(-5) == "0:00")
    }

    @Test func increaseContrastIsReadFromTheThemeAndLiftsTheQuietInks() {
        #expect(LLTheme.stellar.increasedContrast().raisesContrast)
        #expect(LLTheme.wilds.increasedContrast().raisesContrast)
        #expect(!LLTheme.stellar.raisesContrast && !LLTheme.wilds.raisesContrast)
        let base = HomeInk(.stellar), raised = HomeInk(.stellar.increasedContrast())
        #expect(base.value == LLTheme.stellar.ink2 && base.quiet == LLTheme.stellar.ink3)
        #expect(raised.quiet == LLTheme.stellar.ink2)
        // Values rise one step, not to full ink: the action and the chosen word stay the loudest.
        for theme in [LLTheme.stellar, .wilds] {
            func level(_ color: Color) -> Float {
                let c = color.resolve(in: EnvironmentValues())
                return 0.2126 * c.linearRed + 0.7152 * c.linearGreen + 0.0722 * c.linearBlue
            }
            let value = level(HomeInk(theme.increasedContrast()).value)
            let (ink2, ink) = (level(theme.ink2), level(theme.ink))
            #expect(min(ink2, ink) < value && value < max(ink2, ink))
            #expect(abs(value - ink2) > 0.02 && abs(value - ink) > 0.02)
        }
    }
}

/// Each line's dot measured from the line's centre, as `HingedLines` measures it.
private struct DotProbe: Layout {
    let dots: DotSink

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        dots.values = subviews.map { subview in
            let d = subview.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
            return d[.routeHinge] - d.width / 2
        }
        return CGSize(width: proposal.width ?? 0, height: 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}

private final class DotSink: @unchecked Sendable {
    var values: [CGFloat] = []
}
