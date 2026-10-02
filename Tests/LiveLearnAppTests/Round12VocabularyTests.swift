import AppKit
import Foundation
import SwiftUI
import Testing
import CaptionDomain
import CloudEngine
import EngineKit
@testable import LiveLearnApp

/// Round 12 vocabulary ("one star chart"): the star map names its stars beside them and never
/// drops a name on a small page, a fixed translation is a binary star, and the list, the sheets
/// and the corrections speak the same grammar. Geometry is pinned here; how it looks is reviewed
/// from renders (the app's fixtures, and `gallery` below, opt-in).
@MainActor
struct Round12VocabularyTests {
    private func request(_ id: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 60) -> LexiconConstellation.LabelRequest {
        .init(id: id, anchor: CGPoint(x: x, y: y), size: CGSize(width: width, height: 16))
    }

    /// A lone star is named to its right, 8 pt from the point, centred on the point's height.
    @Test func namesSitBesideTheirStars() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let placed = LexiconConstellation.placeLabels([request("a", 100, 100)], reserved: [], bounds: bounds)
        let label = try #require(placed["a"])
        #expect(label.side == .right)
        #expect(label.rect == CGRect(x: 108, y: 92, width: 60, height: 16))
        // Against the right edge the name moves to the left of its star.
        let edge = LexiconConstellation.placeLabels([request("b", 580, 100)], reserved: [], bounds: bounds)
        #expect(edge["b"]?.side == .left && edge["b"]?.rect.maxX == 572)
    }

    /// Two stars side by side: the second name does not land on the first, nor on the other
    /// star's point, when another side is clear.
    @Test func namesAvoidEachOtherAndOtherStars() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let requests = [request("front", 200, 200), request("back", 150, 200, width: 40)]
        let placed = LexiconConstellation.placeLabels(requests, reserved: [], bounds: bounds)
        let front = try #require(placed["front"]), back = try #require(placed["back"])
        #expect(!front.rect.intersects(back.rect))
        #expect(!back.rect.insetBy(dx: -3, dy: -3).contains(CGPoint(x: 200, y: 200)))
        #expect(front.side == .right && back.side != .right)
    }

    /// Up to the label limit every star keeps its name, even crowded into a corner where no
    /// side is clear; past it, at most the limit are named.
    @Test func smallPagesNeverDropNames() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let crowded = (0..<LexiconConstellation.labelLimit).map { request("t\($0)", 150 + CGFloat($0 % 3), 100, width: 90) }
        let placed = LexiconConstellation.placeLabels(crowded, reserved: [], bounds: bounds)
        #expect(placed.count == LexiconConstellation.labelLimit)
        let many = (0..<120).map { request("m\($0)", CGFloat($0 % 12) * 40 + 20, CGFloat($0 / 12) * 40 + 20) }
        let capped = LexiconConstellation.placeLabels(many, reserved: [], bounds: CGRect(x: 0, y: 0, width: 480, height: 400))
        #expect(capped.count <= LexiconConstellation.labelLimit)
        // Over the limit a name is set only where it is clear.
        let values = Array(capped.values)
        for (i, a) in values.enumerated() {
            for b in values[(i + 1)...] { #expect(!a.rect.intersects(b.rect)) }
        }
    }

    /// A name keeps `neighbourClearance` from a neighbour's point beside it, so it never ends
    /// nearer that point than its own: the name moves to the other side while the neighbour keeps
    /// its own.
    @Test func namesKeepClearOfNeighbourPoints() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let placed = LexiconConstellation.placeLabels([request("a", 100, 100), request("b", 178, 101)], reserved: [], bounds: bounds)
        let a = try #require(placed["a"]), b = try #require(placed["b"])
        #expect(a.side == .left && b.side == .right)
        let clearance = LexiconConstellation.neighbourClearance
        #expect(!a.rect.insetBy(dx: -clearance.width, dy: -clearance.height).contains(CGPoint(x: 178, y: 101)))
    }

    /// A neighbour's binary star is kept clear as a whole — its companion as well as its primary,
    /// above and below a name as well as beside it: a render had "SwiftUI" set on a raised slot
    /// right over an unnamed gold pair, its primary just outside the old 4 pt band and its
    /// companion never checked, so the name read as the pair's (and the wrong type).
    @Test func namesKeepClearOfANeighboursBinary() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        var pair = request("b", 120.75, 108.25)
        pair.companion = CGPoint(x: 122, y: 105)
        // The left side is taken (by another name, say), so the raised right slot is the one that
        // tempted the old test.
        let taken = CGRect(x: 20, y: 84, width: 40, height: 32)
        let placed = LexiconConstellation.placeLabels([request("a", 100, 100), pair], reserved: [taken], bounds: bounds)
        let a = try #require(placed["a"])
        #expect(a.slot != LexiconConstellation.LabelSlot(side: .right, nudge: -1))
        let clearance = LexiconConstellation.neighbourClearance
        for point in [pair.anchor, try #require(pair.companion)] {
            #expect(!a.rect.insetBy(dx: -clearance.width, dy: -clearance.height).contains(point))
        }
    }

    /// Before a name is hung above or below its star it tries the four stepped places beside it,
    /// right before left, up before down.
    @Test func namesStepBesideBeforeHanging() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        // Blocks the centred and raised places on both sides, leaves the lowered ones clear.
        let reserved = [CGRect(x: 110, y: 84, width: 50, height: 10), CGRect(x: 30, y: 84, width: 60, height: 10)]
        let placed = LexiconConstellation.placeLabels([request("a", 100, 100)], reserved: reserved, bounds: bounds)
        let label = try #require(placed["a"])
        #expect(label.slot == LexiconConstellation.LabelSlot(side: .right, nudge: 1))
        #expect(label.rect == CGRect(x: 108, y: 97, width: 60, height: 16))
    }

    /// A name keeps the place beside its star it had in the last frame while that stays clear;
    /// a name hung below does not stick there once a side clears.
    @Test func namesKeepTheirPreviousPlace() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let left = LexiconConstellation.LabelSlot(side: .left)
        let kept = LexiconConstellation.placeLabels([request("a", 100, 100)], reserved: [], bounds: bounds, previous: ["a": left])
        #expect(kept["a"]?.slot == left)
        let below = LexiconConstellation.LabelSlot(side: .below)
        let returned = LexiconConstellation.placeLabels([request("a", 100, 100)], reserved: [], bounds: bounds, previous: ["a": below])
        #expect(returned["a"]?.side == .right)
    }

    /// Past the label limit the names spread over the sky — every part of a 4 × 3 grid that
    /// holds stars gets a name, none more than three — instead of filling the front-most band,
    /// and a small sky carries fewer names.
    @Test func crowdedPagesSpreadNames() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 600)
        // A 12 × 10 grid of stars, the front-most (first) along the top.
        let stars = (0..<120).map { request("s\($0)", CGFloat($0 % 12) * 80 + 20, CGFloat($0 / 12) * 60 + 20) }
        let placed = LexiconConstellation.placeLabels(stars, reserved: [], bounds: bounds)
        #expect(placed.count == LexiconConstellation.labelLimit)
        var perCell = [Int: Int]()
        for star in stars where placed[star.id] != nil {
            perCell[Int(star.anchor.y / 200) * 4 + Int(star.anchor.x / 240), default: 0] += 1
        }
        #expect(perCell.count == 12 && perCell.values.allSatisfy { $0 <= 3 })
        // Over the limit a name is set only where it is clear, so no other star's point is
        // within its clearance.
        let clearance = LexiconConstellation.neighbourClearance
        for (id, label) in placed {
            let near = label.rect.insetBy(dx: -clearance.width, dy: -clearance.height)
            #expect(!stars.contains { $0.id != id && near.contains($0.anchor) }, "\(id)")
        }
        let small = CGRect(x: 0, y: 0, width: 752, height: 387)
        let minimum = LexiconConstellation.placeLabels(stars.map { request($0.id, $0.anchor.x * 0.78, $0.anchor.y * 0.64) },
                                                       reserved: [], bounds: small)
        #expect(minimum.count <= 18)
    }

    /// At the resting camera the dust keeps an even margin, at least 28 pt, above it and below it
    /// (the sky above the floating count and camera row), at the minimum and default windows.
    @Test func fieldSitsCentredInTheSky() {
        for field in [CGSize(width: 776, height: 403), CGSize(width: 996, height: 558)] {
            let ys = LexiconConstellation.dust.map {
                LexiconConstellation.project($0.position, size: field, yaw: 0, tilt: 0.52, zoom: 1).point.y
            }
            let top = ys.min() ?? 0, bottom = field.height - (ys.max() ?? 0)
            #expect(top >= 28 && bottom >= 28, "\(field): \(top) / \(bottom)")
            #expect(abs(top - bottom) < 4, "\(field): \(top) / \(bottom)")
        }
    }

    /// Reserved areas (the selected star's annotation) are kept clear of other names.
    @Test func namesKeepClearOfTheAnnotation() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let annotation = CGRect(x: 108, y: 60, width: 200, height: 80)
        let placed = LexiconConstellation.placeLabels([request("a", 100, 100)], reserved: [annotation], bounds: bounds)
        let label = try #require(placed["a"])
        #expect(!label.rect.intersects(annotation))
        #expect(label.side == .left)
    }

    /// The depth share spans every term position at any camera and stays in 0…1.
    @Test func depthShareCoversTheField() {
        #expect(LexiconConstellation.depthShare(-0.97) == 0)
        #expect(LexiconConstellation.depthShare(0.97) == 1)
        #expect(LexiconConstellation.depthShare(-5) == 0 && LexiconConstellation.depthShare(5) == 1)
        let items = VocabularyLibrary(hotWords: (0..<120).map { "t\($0)" }).items
        for tilt in [0.18, 0.52, 1.05] {
            for node in LexiconConstellation.nodes(items, page: 0) {
                let depth = LexiconConstellation.project(node.position, size: CGSize(width: 900, height: 600), yaw: 1.3, tilt: tilt, zoom: 1).depth
                #expect(abs(depth) <= 0.97)
            }
        }
    }

    /// A binary star reads as one star: its points are under 4 pt apart, the companion is the
    /// lesser, and in the static mark the pair straddles the slot's centre.
    @Test func binaryStarsStayOneStar() {
        #expect(LexiconConstellation.binarySeparation < 4 && LexiconConstellation.companionScale < 1)
        let centre = CGPoint(x: 6, y: 6)
        let pair = VocabularyKindMark.points(.glossary, lit: false, centre: centre, paper: false)
        #expect(pair.count == 2 && pair[1].diameter < pair[0].diameter)
        let gap = hypot(pair[0].at.x - pair[1].at.x, pair[0].at.y - pair[1].at.y)
        #expect(abs(gap - LexiconConstellation.binarySeparation) < 0.001)
        #expect(abs((pair[0].at.x + pair[1].at.x) / 2 - centre.x) < 0.001)
        #expect(VocabularyKindMark.points(.hotWord, lit: false, centre: centre, paper: false).count == 1)
        // Lit, the star is the primary: only the companion is left to draw, and only for a pair.
        #expect(VocabularyKindMark.points(.hotWord, lit: true, centre: centre, paper: false).isEmpty)
        #expect(VocabularyKindMark.points(.glossary, lit: true, centre: centre, paper: false).count == 1)
        // The companion turns with the camera and nothing else.
        let a = LexiconConstellation.companionAngle(for: "glossary:x=y", yaw: 0)
        #expect(abs(LexiconConstellation.companionAngle(for: "glossary:x=y", yaw: 0.5) - a - 0.5) < 1e-9)
    }

    /// The dust never takes the term hues; a pearl grain is rare.
    @Test func dustIsNeutralAndPearlIsRare() {
        let pearls = LexiconConstellation.dust.filter(\.pearl).count
        #expect(pearls > 0 && pearls < LexiconConstellation.dust.count / 12)
        #expect(LexiconConstellation.dust.allSatisfy { (0...1).contains($0.brightness) })
    }

    @Test func packSampleShowsTheFirstWords() {
        let pack = VocabularyStarterPack.all[0]
        #expect(pack.sample == "SwiftUI · Kubernetes · GitHub · API · machine learning …")
        let short = VocabularyStarterPack(id: "s", title: "", subtitle: "", text: "a=甲\nb")
        #expect(short.sample == "a · b")
    }

    /// The translations' column sits a gap past the longest word that has a translation (hot
    /// words take the whole row and do not count), never under its minimum or past 45 % of the
    /// row — the import preview (16 pt gap) and the page's list (24 pt, at least 160) alike.
    @Test func translationColumnFollowsTheLongestPair() {
        let font = NSFont.systemFont(ofSize: 13)
        let items = VocabularyLibrary(hotWords: [String(repeating: "w", count: 30)], glossaryLines: ["a=甲", "latency=延迟"]).items
        let width = ceil(("latency" as NSString).size(withAttributes: [.font: font]).width)
        let widest = VocabularyPageMetrics.widestGlossaryWord(in: items, font: font)
        #expect(widest == width)
        // Asked again (a new body), the same words give the same width.
        #expect(VocabularyPageMetrics.widestGlossaryWord(in: items, font: font) == width)
        // Another font is another measurement.
        #expect(VocabularyPageMetrics.widestGlossaryWord(in: items, font: .systemFont(ofSize: 26)) > width)
        #expect(VocabularyPageMetrics.translationColumn(widest: widest, rowWidth: 400, gap: 16) == width + 16)
        #expect(VocabularyPageMetrics.translationColumn(widest: widest, rowWidth: 600, gap: 24, minimum: 160) == 160)
        let long = VocabularyPageMetrics.widestGlossaryWord(in: VocabularyLibrary(glossaryLines: [String(repeating: "m", count: 80) + "=长"]).items, font: font)
        #expect(VocabularyPageMetrics.translationColumn(widest: long, rowWidth: 400, gap: 16) == 180)
        #expect(VocabularyPageMetrics.translationColumn(widest: long, rowWidth: 300, gap: 24, minimum: 160) == 135)
        #expect(VocabularyPageMetrics.widestGlossaryWord(in: VocabularyLibrary(hotWords: ["only"]).items, font: font) == 0)
    }

    /// The misheard span is dotted in place; a span that no longer matches is left unmarked.
    @Test func correctionsMarkTheMisheardSpan() {
        let text = "Open live lawn，用飞鼠开会。"
        let spans = [VocabularyCorrectionCandidate(start: 5, length: 9, original: "live lawn", replacement: "LiveLearn", reason: .similarSpelling),
                     VocabularyCorrectionCandidate(start: 0, length: 2, original: "no", replacement: "x", reason: .similarSpelling)]
        let marked = VocabularyCorrectionsView.marked(text, spans: spans, ink: .white, mark: .orange)
        let underlined = marked.runs.filter { $0.underlineStyle != nil }.map { String(marked[$0.range].characters) }
        #expect(underlined == ["live lawn"])
        #expect(String(marked.characters) == text)
    }

    /// Opt-in review renders of the states the app's fixtures do not reach (a selected star, a
    /// selected list row, the sheets and the corrections in both themes):
    /// `LIVELEARN_R12_GALLERY=<dir> swift test --filter Round12VocabularyTests/gallery`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_R12_GALLERY"] != nil))
    func gallery() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_R12_GALLERY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ view: some View, _ name: String, theme: LLTheme, size: CGSize) throws {
            let root = ThemedRoot(forced: theme) { view }
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
                .environment(\.staticRender, true)
                .frame(width: size.width, height: size.height)
                .background(theme.ground)
            let image = try renderedImage(root, scale: 2)
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        let library = VocabularyLibrary(hotWords: ["LiveLearn", "WhisperKit", "语音识别", "SwiftUI", "Metal"],
                                        glossaryLines: ["latency=时延", "machine learning=机器学习", "embedding=嵌入", "inference=推理"])
        for (index, id) in [library.items[0].id, library.items[6].id].enumerated() {
            try save(VocabularyStarMap(items: library.items, isSearching: false, isVisible: true, selectedID: .constant(id),
                                       onAdd: {}, onClearSearch: {}, onEdit: { _ in }),
                     "starmap-selected-\(index)", theme: .stellar, size: CGSize(width: 900, height: 560))
        }
        try save(VocabularyStarMap(items: library.items, isSearching: false, isVisible: true, selectedID: .constant(nil),
                                   onAdd: {}, onClearSearch: {}, onEdit: { _ in })
                    .environment(\._colorSchemeContrast, .increased),
                 "starmap-contrast", theme: LLTheme.stellar.increasedContrast(), size: CGSize(width: 900, height: 560))
        for theme in [LLTheme.stellar, .wilds] {
            let suffix = theme.isDark ? "dark" : "light"
            try save(VocabularyEditor(draft: VocabularyEditorDraft(original: nil, kind: .glossary, source: "latency", target: ""),
                                      library: library, onSave: { _ in }, onCancel: {}),
                     "editor-\(suffix)", theme: theme, size: CGSize(width: 560, height: 260))
            try save(VocabularyImportView(text: .constant(""), library: library, onImport: { _ in }, onCancel: {},
                                          onChooseFile: {}, onLoadFile: { _ in }),
                     "import-empty-\(suffix)", theme: theme, size: CGSize(width: 520, height: 280))
            try save(VocabularyImportView(text: .constant("WhisperKit\nmachine learning=机器学习\nretry storm=重试风暴\nlatency=延迟"),
                                          library: VocabularyLibrary(), onImport: { _ in }, onCancel: {}, onChooseFile: {},
                                          onLoadFile: { _ in }, previewExpanded: true),
                     "import-review-\(suffix)", theme: theme, size: CGSize(width: 520, height: 440))
            try save(VocabularyKindSheet(), "kind-marks-\(suffix)", theme: theme, size: CGSize(width: 320, height: 90))
        }
        let suite = "LiveLearn.testing.r12-gallery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.hotWords = library.hotWords
        settings.glossaryLines = library.glossaryLines
        let model = AppModel(settings: settings, preview: .empty())
        var snapshot = SampleData.runningSnapshot(includeGap: false)
        if case .segment(var segment) = snapshot.captions.items[0] {
            segment.sourceText = "Open live lawn，用飞鼠开会。"
            segment.sourceFinal = true
            segment.vocabularyCandidates = VocabularyCandidateGenerator(vocabulary: ["LiveLearn", "飞书"]).candidates(in: segment.sourceText)
            snapshot.captions.items = [.segment(segment)]
        }
        let reviewing = AppModel(settings: settings, preview: snapshot)
        let chosen = library.items.first { $0.source == "machine learning" }?.id
        for theme in [LLTheme.stellar, .wilds] {
            let suffix = theme.isDark ? "dark" : "light"
            try save(VocabularyWindowView(previewStarMap: false, previewSelectedID: chosen).environment(model),
                     "list-selected-\(suffix)", theme: theme, size: VocabularyWindowView.size)
            try save(VocabularyWindowView(previewSection: .corrections).environment(reviewing),
                     "corrections-\(suffix)", theme: theme, size: VocabularyWindowView.size)
        }
    }
}

/// The type marks, unlit and lit, for the gallery.
private struct VocabularyKindSheet: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 28) {
            ForEach([false, true], id: \.self) { lit in
                HStack(spacing: 16) {
                    VocabularyKindMark(kind: .hotWord, lit: lit)
                    VocabularyKindMark(kind: .glossary, lit: lit)
                }
            }
        }
        .scaleEffect(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
