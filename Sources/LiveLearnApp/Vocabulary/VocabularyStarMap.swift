import SwiftUI
import AppKit
import CloudEngine

/// The dark vocabulary page's sky (round 12, "one star chart"): every term is a point of light
/// on the true-black ground, named beside itself the way a printed star chart names its stars.
///
/// - Light comes only from points: no haze, no chips, no cards. The one `Canvas` draws the
///   orbits, the dust, the distant stars and the terms' light in a fixed number of batched fills
///   (dust 8, orbits 4, term cores ≤ 8) plus one sprite blit per term halo.
/// - A hot word is a single star; a word with a fixed translation is a binary star (two points
///   sharing one halo) — shape, not only hue, says which. Depth grades size and brightness and
///   claims nothing about the word.
/// - Names are silver and bare, with a ground-coloured halo so dust never crosses a letter. The
///   selected star is annotated beside itself (word, translation, 编辑) instead of in a card.
/// - The count and the camera float on the sky's lower edge; the gesture hint appears only
///   while the pointer is over the map.
struct VocabularyStarMap: View {
    let items: [VocabularyItem]
    let isSearching: Bool
    let isVisible: Bool
    @Binding var selectedID: String?
    let onAdd: () -> Void
    let onClearSearch: () -> Void
    let onEdit: (VocabularyItem) -> Void
    /// The empty sky's second way in (导入文件); nil leaves only 添加词汇.
    var onImport: (() -> Void)? = nil
    /// The session's horizon runs under the page: the floating chrome gives way to it (`chrome`).
    var yieldsToHorizon = false
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var page = 0
    @State private var yaw = 0.0
    @State private var tilt = 0.52
    @State private var zoom = 1.0
    @State private var paused = false
    @State private var hovering = false
    @State private var hoveredID: String?
    @State private var appActive = NSApp?.isActive ?? true
    @State private var windowVisible = false
    @FocusState private var keyboardFocus: String?
    /// The camera or paging glyph under keyboard focus (`ChromeAction.id`).
    @FocusState private var chromeFocus: String?
    @AccessibilityFocusState private var accessibilityFocus: String?
    @State private var elapsed = 0.0
    @State private var motionStart = Date()
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification = 1.0
    /// Where each name sat in the last frame (see `LexiconConstellation.placeLabels`). A plain
    /// reference: rewriting it while a frame is laid out must not invalidate the view.
    @State private var labelMemory = LabelMemory()

    private final class LabelMemory {
        var slots: [String: LexiconConstellation.LabelSlot] = [:]
    }

    /// A fixed translation's halo sprite tint as `RRGGBB` (a hot word's is `theme.starBlueHex`):
    /// a champagne lighter than its `ochre` core — an ochre halo on the black ground reads as a
    /// brown disc, and the hue belongs in the point.
    private static let glossaryHaloHex: UInt32 = 0xEFE3CC
    /// The floating count and camera row along the sky's lower edge. The field is fitted to the
    /// sky above it, and names stay clear of it.
    private static let chromeHeight: CGFloat = 40
    /// Half the side of the square kept free of names over the field's nucleus (at zoom 1): the
    /// nucleus is the dust's brightest region, and a name's ground halo would punch a hole in it.
    private static let nucleusClearance: CGFloat = 36
    private static let labelHeight: CGFloat = 16
    private static let annotationWidth: CGFloat = 240

    private var selection: VocabularyItem? { items.first { $0.id == selectedID } }
    private var moving: Bool { isVisible && appActive && windowVisible && !staticRender && !reduceMotion && !paused && !hovering && selectedID == nil && keyboardFocus == nil && accessibilityFocus == nil }
    /// The star whose name is lifted: under the pointer, else under keyboard focus.
    private var emphasisedID: String? { hoveredID ?? keyboardFocus }

    private struct MeasuredNode {
        let node: LexiconConstellation.Node
        /// Name widths at rest (12/400) and lifted (13/500), capped at 158.
        let widths: (rest: CGFloat, lifted: CGFloat)
    }
    private var measuredNodes: [MeasuredNode] {
        LexiconConstellation.nodes(items, page: page).map { node in
            func width(_ font: NSFont) -> CGFloat {
                min(158, ceil((node.item.source as NSString).size(withAttributes: [.font: font]).width) + 2)
            }
            return MeasuredNode(node: node, widths: (width(.systemFont(ofSize: 12)), width(.systemFont(ofSize: 13, weight: .medium))))
        }
    }

    var body: some View {
        // Static node geometry and text metrics are prepared once per content update,
        // outside the projection closure.
        let measuredNodes = self.measuredNodes
        GeometryReader { geometry in
            // The field turns at 0.025 rad/s: at 20 frames a second a star moves a tenth
            // of a point per frame at the rim, so the lower rate is invisible and repositions
            // the star buttons a third less often.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { timeline in
                let time = elapsed + (moving ? max(0, timeline.date.timeIntervalSince(motionStart)) : 0)
                let camera = Camera(yaw: yaw + time * 0.025 + drag.width * 0.006,
                                    tilt: min(1.05, max(0.18, tilt + drag.height * 0.004)),
                                    zoom: min(1.6, max(0.7, zoom * magnification)))
                let chart = items.isEmpty ? Chart() : chart(nodes: measuredNodes, size: geometry.size, camera: camera)
                ZStack(alignment: .topLeading) {
                    sky(camera: camera, stars: chart.stars)
                        .contentShape(Rectangle())
                        .gesture(rotationGesture)
                        .gesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }
                            .onEnded { zoom = min(1.6, max(0.7, zoom * $0.magnification)) })
                    ForEach(chart.stars) { star in
                        interactiveStar(star)
                            .position(x: star.hit.midX, y: star.hit.midY)
                            .zIndex(star.id == selectedID ? 2 : (star.label == nil ? 0 : 1))
                    }
                    if let annotation = chart.annotation, let selection {
                        self.annotation(selection, annotation)
                            .zIndex(3)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !items.isEmpty { chrome }
            }
            .onHover { hovering = $0 }
            .overlay {
                if items.isEmpty { emptyState }
            }
            .clipped()
        }
        .background {
            if !staticRender { StarMapVisibility { windowVisible = $0 }.allowsHitTesting(false).accessibilityHidden(true) }
        }
        .onAppear { revealSelection() }
        .onChange(of: items.map(\.id)) { _, _ in page = LexiconConstellation.page(containing: selectedID, in: items) ?? 0 }
        .onChange(of: selectedID) { _, _ in revealSelection() }
        .onChange(of: moving) { old, new in
            if old { elapsed += max(0, Date().timeIntervalSince(motionStart)) }
            if new { motionStart = Date() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("词汇星图")
        .accessibilityActions {
            // Only where the chrome would stand: an empty sky has no camera to offer.
            if !showsCamera && !items.isEmpty {
                ForEach(cameraActions.filter { !$0.disabled }, id: \.id) { action in
                    Button(action.title, action: action.perform)
                }
            }
        }
    }

    private func revealSelection() {
        if let selectedPage = LexiconConstellation.page(containing: selectedID, in: items) { page = selectedPage }
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                yaw += value.translation.width * 0.006
                tilt = min(1.05, max(0.18, tilt + value.translation.height * 0.004))
            }
    }

    private struct Camera {
        let yaw: Double
        let tilt: Double
        let zoom: Double
    }

    // MARK: Chart (one frame's geometry)

    private struct Star: Identifiable {
        let node: LexiconConstellation.Node
        let point: CGPoint
        /// The translation's point of a binary star.
        let companion: CGPoint?
        /// 0 at the back of the field, 1 at the front.
        let share: Double
        let label: LexiconConstellation.PlacedLabel?
        /// The button: the point's 24 pt square, joined with the name when there is one.
        let hit: CGRect
        var id: String { node.id }
    }

    private struct Annotation {
        let rect: CGRect
        /// Set to the left of its star (the right would leave the sky), its lines aligned to
        /// the edge nearest the star.
        let leading: Bool
    }

    private struct Chart {
        var stars: [Star] = []
        var annotation: Annotation?
    }

    /// The area the field is fitted to: the sky above the floating count and camera row.
    private static func field(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(1, size.height - chromeHeight))
    }

    private func chart(nodes: [MeasuredNode], size: CGSize, camera: Camera) -> Chart {
        let field = Self.field(size)
        func project(_ point: LexiconConstellation.Point) -> LexiconConstellation.Projection {
            LexiconConstellation.project(point, size: field, yaw: camera.yaw, tilt: camera.tilt, zoom: camera.zoom)
        }
        // A binary star's companion, placed here once so the names keep clear of the point that
        // is drawn.
        let projected = nodes.map { measured in
            let projection = project(measured.node.position)
            var companion: CGPoint?
            if measured.node.item.kind == .glossary {
                let angle = LexiconConstellation.companionAngle(for: measured.node.id, yaw: camera.yaw)
                companion = CGPoint(x: projection.point.x + cos(angle) * LexiconConstellation.binarySeparation,
                                    y: projection.point.y + sin(angle) * LexiconConstellation.binarySeparation)
            }
            return (measured, projection, companion)
        }
        // Names stay 12 pt inside the sky and clear of the floating count and camera row, of the
        // nucleus, and of the selected star's point and annotation.
        let band = CGRect(x: 12, y: 12, width: max(0, size.width - 24), height: max(0, size.height - 12 - Self.chromeHeight - 4))
        let nucleus = project(.init(x: 0, y: 0, z: 0)).point
        let clearance = Self.nucleusClearance * camera.zoom
        var reserved = [CGRect(x: nucleus.x - clearance, y: nucleus.y - clearance, width: clearance * 2, height: clearance * 2)]
        var annotation: Annotation?
        if let selected = projected.first(where: { $0.0.node.id == selectedID }) {
            let placed = annotationRect(for: selected.0.node.item, at: selected.1.point, band: band)
            annotation = placed
            reserved.append(placed.rect.insetBy(dx: -4, dy: -4))
            reserved.append(CGRect(x: selected.1.point.x - 12, y: selected.1.point.y - 12, width: 24, height: 24))
        }
        // Names are set front to back at their resting size. A lifted name (hovered, focused)
        // keeps the side and edge it was given and grows away from its star: re-placing it
        // could move it out from under the pointer, which would end the hover and loop.
        let requests = projected
            .filter { $0.0.node.id != selectedID }
            .sorted { $0.1.depth > $1.1.depth }
            .map { measured, projection, companion in
                LexiconConstellation.LabelRequest(id: measured.node.id, anchor: projection.point,
                    size: CGSize(width: measured.widths.rest, height: Self.labelHeight), companion: companion)
            }
        let labels = LexiconConstellation.placeLabels(requests, reserved: reserved, bounds: band, previous: labelMemory.slots)
        labelMemory.slots = labels.mapValues(\.slot)
        let emphasised = emphasisedID
        let stars = projected.map { measured, projection, companion in
            let node = measured.node
            let label = labels[node.id].map { placed in
                node.id == emphasised
                    ? LexiconConstellation.PlacedLabel(rect: Self.lifted(placed.rect, to: measured.widths.lifted, side: placed.side), slot: placed.slot)
                    : placed
            }
            let square = CGRect(x: projection.point.x - 12, y: projection.point.y - 12, width: 24, height: 24)
            return Star(node: node, point: projection.point, companion: companion,
                        share: LexiconConstellation.depthShare(projection.depth), label: label,
                        hit: label.map { square.union($0.rect) } ?? square)
        }
        // Re-sorted by id so keyboard focus order stays stable while the field turns.
        return Chart(stars: stars.sorted { $0.id < $1.id }, annotation: annotation)
    }

    /// A name's box at its lifted width, grown away from its star: from the same near edge
    /// beside the star, from the same centre above or below it.
    private static func lifted(_ rect: CGRect, to width: CGFloat, side: LexiconConstellation.LabelSide) -> CGRect {
        switch side {
        case .right: return CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        case .left: return CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
        case .above, .below: return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
    }

    /// The selected star's annotation box: to the right of the star with its first line on the
    /// star's height, or to the left when the right side would leave the sky. It never leaves the
    /// sky itself: a star outside it (reached by keyboard, or a new word while zoomed in) has its
    /// annotation held at the nearest edge, so 编辑 and ✕ stay in reach.
    private func annotationRect(for item: VocabularyItem, at point: CGPoint, band: CGRect) -> Annotation {
        let heading = NSFont.systemFont(ofSize: 15, weight: .medium), body = NSFont.systemFont(ofSize: 13)
        let detail = LexiconConstellation.detail(for: item)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        }
        let w = min(Self.annotationWidth, max(96, width(item.source, heading), width(detail, body)))
        // Each text block at its wrapped height in that width (two lines at most, as drawn), the
        // two 2 pt spacings, and the 28 pt row of 编辑 and ✕.
        func height(_ text: String, _ font: NSFont) -> CGFloat {
            func measure(_ text: String, width: CGFloat) -> CGFloat {
                (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
            }
            return ceil(min(measure(text, width: w), measure("中Ag", width: .greatestFiniteMagnitude) * 2))
        }
        let h = height(item.source, heading) + 2 + height(detail, body) + 2 + 28
        let leading = point.x + 14 + w > band.maxX
        let x = min(max(leading ? point.x - 14 - w : point.x + 14, band.minX), max(band.minX, band.maxX - w))
        let y = min(max(point.y - 10, band.minY), max(band.minY, band.maxY - h))
        return Annotation(rect: CGRect(x: x, y: y, width: w, height: h), leading: leading)
    }

    // MARK: Sky

    private func sky(camera: Camera, stars: [Star]) -> some View {
        Canvas { context, bounds in
            let increased = contrast == .increased
            let field = Self.field(bounds)
            func project(_ point: LexiconConstellation.Point) -> LexiconConstellation.Projection {
                LexiconConstellation.project(point, size: field, yaw: camera.yaw, tilt: camera.tilt, zoom: camera.zoom)
            }
            // Coordinate orbits, lit from the front: each arc's ink follows its depth (the back
            // arc at 35 % of the front), in four strokes shared by the three orbits. They establish
            // depth without implying relationships.
            let front = increased ? 0.24 : 0.10
            var arcs = Array(repeating: Path(), count: 4)
            for orbit in [0.45, 0.78, 1.10] {
                let reach = orbit * max(0.1, cos(camera.tilt))
                var previous: LexiconConstellation.Projection?
                for step in 0...160 {
                    let a = Double(step) / 160 * .pi * 2
                    let next = project(.init(x: cos(a) * orbit, y: 0, z: sin(a) * orbit))
                    if let previous {
                        let share = min(1, max(0, ((previous.depth + next.depth) / 2 / reach + 1) / 2))
                        let bucket = min(3, Int(share * 4))
                        arcs[bucket].move(to: previous.point)
                        arcs[bucket].addLine(to: next.point)
                    }
                    previous = next
                }
            }
            for (bucket, path) in arcs.enumerated() {
                let share = (Double(bucket) + 0.5) / 4
                context.stroke(path, with: .color(theme.accent.opacity(front * (0.35 + 0.65 * share))), lineWidth: 0.6)
            }
            // Dust, batched by ink: six silver levels (brightness × depth) and two pearl levels. The
            // brighter pearl stays about a tenth under the back-most term core (`drawTerms`).
            var clouds = Array(repeating: Path(), count: 8)
            for dust in LexiconConstellation.dust {
                let projection = project(dust.position)
                let r = dust.radius * camera.zoom
                let lit = dust.brightness * (0.7 + 0.3 * LexiconConstellation.depthShare(projection.depth))
                let bucket = dust.pearl ? (lit > 0.5 ? 7 : 6) : min(5, Int(lit * 6))
                clouds[bucket].addEllipse(in: CGRect(x: projection.point.x - r / 2, y: projection.point.y - r / 2, width: r, height: r))
            }
            let silver = [0.22, 0.30, 0.38, 0.47, 0.56, 0.66]
            for (bucket, path) in clouds.enumerated() {
                let ink = bucket < 6 ? theme.ink2.opacity(silver[bucket]) : Color(hex: 0xE9EEF5, alpha: bucket == 6 ? 0.48 : 0.6)
                context.fill(path, with: .color(ink))
            }
            // Distant stars: fine points only, no cross glints. The brighter ones keep to the sky
            // above the floating count and camera row, where one would read as a stray control dot.
            var distant = Path(), bright = Path()
            for index in 0..<85 {
                let key = "distant-\(index)"
                let x = LexiconConstellation.fraction(key) * bounds.width
                let fraction = LexiconConstellation.fraction(key, salt: 33)
                if index % 13 == 0 {
                    let y = 12 + fraction * max(0, bounds.height - Self.chromeHeight - 20)
                    bright.addEllipse(in: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7))
                } else {
                    let y = fraction * bounds.height
                    distant.addEllipse(in: CGRect(x: x - 0.4, y: y - 0.4, width: 0.8, height: 0.8))
                }
            }
            context.fill(distant, with: .color(theme.ink2.opacity(0.22)))
            context.fill(bright, with: .color(theme.ink2.opacity(0.65)))
            drawTerms(stars, in: &context, increased: increased)
        }
        .accessibilityHidden(true)
    }

    /// The terms' light: a soft halo sprite per star (one per binary pair, centred between its
    /// points), then the cores in at most eight fills (two hues × four brightness levels), then
    /// the selected star's rays — the settings star's two 0.5 pt rays, reaching past its core.
    ///
    /// Depth grades the stars against each other, never below the dust: the back-most core is
    /// still 2.4 pt at 78 %, brighter than the nucleus and the pearl grains around it — the data
    /// is the brightest thing in the sky. Resting halos thin out as a page fills (full up to 32
    /// stars, about half at 120): a crowded page's halos would otherwise merge into a blue wash,
    /// and light must stay with the points.
    private func drawTerms(_ stars: [Star], in context: inout GraphicsContext, increased: Bool) {
        guard !stars.isEmpty else { return }
        let crowding = min(1, (32 / Double(max(32, stars.count))).squareRoot())
        let sprites = [context.resolve(ParticleSprites.halo(theme.starBlueHex)), context.resolve(ParticleSprites.halo(Self.glossaryHaloHex))]
        var cores = Array(repeating: Path(), count: 8)
        var rays = [Path(), Path()]
        for star in stars {
            let hue = star.node.item.kind == .hotWord ? 0 : 1
            let selected = star.id == selectedID
            let lifted = selected || star.id == emphasisedID
            let t = star.share
            if !increased {
                let centre = star.companion.map { CGPoint(x: (star.point.x + $0.x) / 2, y: (star.point.y + $0.y) / 2) } ?? star.point
                let r = selected ? 14 : (lifted ? 10 + 4 * t : 8 + 4 * t)
                var halo = context
                halo.opacity = selected ? 0.42 : (lifted ? 0.36 : (0.20 + 0.12 * t) * crowding)
                halo.draw(sprites[hue], in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            }
            let d = 2.4 + 1.4 * t + (selected ? 0.6 : 0)
            let level = lifted || increased ? 3 : min(3, Int(t * 4))
            cores[hue * 4 + level].addEllipse(in: CGRect(x: star.point.x - d / 2, y: star.point.y - d / 2, width: d, height: d))
            if let companion = star.companion {
                let c = d * LexiconConstellation.companionScale
                cores[hue * 4 + level].addEllipse(in: CGRect(x: companion.x - c / 2, y: companion.y - c / 2, width: c, height: c))
            }
            if selected {
                let reach = d / 2 + 4
                rays[hue].move(to: CGPoint(x: star.point.x - reach, y: star.point.y))
                rays[hue].addLine(to: CGPoint(x: star.point.x + reach, y: star.point.y))
                rays[hue].move(to: CGPoint(x: star.point.x, y: star.point.y - reach))
                rays[hue].addLine(to: CGPoint(x: star.point.x, y: star.point.y + reach))
            }
        }
        let tints = [theme.starBlue, theme.ochre]
        let levels = [0.78, 0.86, 0.93, 1.0]
        for (index, path) in cores.enumerated() where !path.isEmpty {
            context.fill(path, with: .color(tints[index / 4].opacity(levels[index % 4])))
        }
        for (hue, path) in rays.enumerated() where !path.isEmpty {
            context.stroke(path, with: .color(tints[hue].opacity(increased ? 1 : 0.55)), lineWidth: 0.5)
        }
    }

    // MARK: Stars (buttons) and names

    @ViewBuilder private func interactiveStar(_ star: Star) -> some View {
        // ImageRenderer cannot draw native focus bridges; keep the same visible label.
        if staticRender { starButton(star) }
        else {
            starButton(star)
                .focused($keyboardFocus, equals: star.id)
                .accessibilityFocused($accessibilityFocus, equals: star.id)
        }
    }

    /// A native button over the star's point and its name. The light is the sky's; the button
    /// carries the name, the hit area, the focus ring and everything VoiceOver reads.
    private func starButton(_ star: Star) -> some View {
        let item = star.node.item
        let selected = selectedID == item.id
        let lifted = emphasisedID == item.id
        return Button { selectedID = item.id } label: {
            ZStack(alignment: .topLeading) {
                Color.clear
                if let label = star.label, !selected {
                    Text(item.source)
                        .font(lifted ? .system(size: 13, weight: .medium) : .system(size: 12))
                        // Names at the back of the field recede with their stars (a depth cue only;
                        // Increase Contrast keeps every name at ink2).
                        .foregroundStyle(lifted ? theme.ink : (star.share < 0.4 && contrast != .increased ? theme.ink3 : theme.ink2))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: label.rect.width, height: label.rect.height, alignment: alignment(label.side))
                        .groundHalo(theme.ground)
                        .offset(x: label.rect.minX - star.hit.minX, y: label.rect.minY - star.hit.minY)
                }
            }
            .frame(width: star.hit.width, height: star.hit.height)
            .contentShape(Rectangle())
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
        }
        .buttonStyle(PressDimStyle())
        .onHover { inside in
            if inside { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
        }
        .accessibilityLabel(item.source + "，" + LexiconConstellation.detail(for: item))
        .accessibilityHint("查看词汇详情")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(item.target.isEmpty ? item.source : "\(item.source) → \(item.target)")
    }

    private func alignment(_ side: LexiconConstellation.LabelSide) -> Alignment {
        switch side {
        case .right: return .leading
        case .left: return .trailing
        case .above, .below: return .center
        }
    }

    /// The selection, written into the sky beside its star: the word, its translation (or what
    /// a hot word does), then 编辑 and ✕ — the old inspector's content and actions without its
    /// card, stroke and shadow.
    private func annotation(_ item: VocabularyItem, _ annotation: Annotation) -> some View {
        VStack(alignment: annotation.leading ? .trailing : .leading, spacing: 2) {
            Text(item.source).font(LLFont.heading).foregroundStyle(theme.ink)
                .lineLimit(2).textSelection(.enabled)
            Text(LexiconConstellation.detail(for: item))
                .font(LLFont.body).foregroundStyle(item.isValid ? theme.ink2 : theme.brick)
                .lineLimit(2).textSelection(.enabled)
            HStack(spacing: 10) {
                Button("编辑") { onEdit(item) }.buttonStyle(TextButtonStyle(flush: true))
                Button { selectedID = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(GlyphButtonStyle(tint: theme.ink3))
                    .accessibilityLabel("关闭词汇详情")
            }
        }
        .multilineTextAlignment(annotation.leading ? .trailing : .leading)
        .groundHalo(theme.ground)
        .frame(width: annotation.rect.width, alignment: annotation.leading ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .offset(x: annotation.rect.minX, y: annotation.rect.minY)
    }

    // MARK: Empty sky

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(isSearching ? "这片星域还没有匹配的词" : "点亮你的第一颗词星")
                .font(LLFont.display).foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Text(isSearching ? "试试其他词汇或译法。" : "把听见的词，连成自己的星河。")
                .font(LLFont.body).foregroundStyle(theme.ink2)
            // The same text actions as the list's empty page, centred on the sky.
            HStack(spacing: 20) {
                emptyAction(isSearching ? "清除搜索" : "添加词汇",
                            help: isSearching ? "清除关键词，显示全部词汇" : "添加热词或固定译法 · ⌘N",
                            action: isSearching ? onClearSearch : onAdd)
                if !isSearching, let onImport {
                    emptyAction("导入文件", help: "粘贴或导入多行词汇", action: onImport)
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
        .background {
            Ellipse().fill(RadialGradient(colors: [theme.ground.opacity(0.95), .clear],
                                          center: .center, startRadius: 10, endRadius: 260))
                .blur(radius: 18).padding(-40).allowsHitTesting(false)
        }
    }

    private func emptyAction(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(TextButtonStyle(flush: true, strong: true))
            .help(help)
    }

    // MARK: Floating chrome

    /// Count and paging bottom-left on the content column, camera glyphs bottom-right on the
    /// page's rag — 11 pt `ink3`, on the sky itself with no rule or strip under them.
    ///
    /// During a session the page's lower edge is the transport's horizon (`yieldsToHorizon`), and
    /// a second row of glyphs over its rule would stack four bands above the dock: the camera
    /// then waits for the pointer on the map or keyboard focus in it, and the count, which the
    /// rail already gives, stays only while it counts a search. The row keeps its height, so the
    /// field and the names do not move. Hidden glyphs leave the accessibility tree, so the map
    /// then offers the camera as its own VoiceOver actions.
    private var chrome: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                mapCount
                Spacer(minLength: 8)
                Text("拖动旋转 · 双指缩放").font(LLFont.label).foregroundStyle(theme.ink3)
                    .opacity(hovering && selectedID == nil && !staticRender ? 1 : 0)
                controls
            }
            HStack(spacing: 12) { mapCount; Spacer(minLength: 8); controls }
        }
        .padding(.leading, VocabularyPageMetrics.contentLeading)
        .padding(.trailing, VocabularyPageMetrics.contentTrailing)
        .frame(height: Self.chromeHeight)
        .animation(LLMotion.hover(reduceMotion), value: hovering)
        .animation(LLMotion.hover(reduceMotion), value: chromeFocus != nil || keyboardFocus != nil)
    }

    private var showsCamera: Bool { !yieldsToHorizon || hovering || chromeFocus != nil || keyboardFocus != nil }

    private var mapCount: some View {
        HStack(spacing: 4) {
            if !yieldsToHorizon || isSearching {
                Text("\(items.count) 个词汇").font(LLFont.timestamp).foregroundStyle(theme.ink3)
            }
            if LexiconConstellation.pageCount(items.count) > 1 {
                control(.init(id: "previous", title: "上一片星域", symbol: "chevron.left", disabled: page == 0) { page -= 1; selectedID = nil })
                Text("\(page + 1)/\(LexiconConstellation.pageCount(items.count))").font(LLFont.timestamp).foregroundStyle(theme.ink3)
                control(.init(id: "next", title: "下一片星域", symbol: "chevron.right", disabled: page + 1 >= LexiconConstellation.pageCount(items.count)) {
                    page += 1; selectedID = nil
                })
            }
        }
        .fixedSize()
    }

    /// A glyph on the floating chrome. `id` holds keyboard focus while the title changes
    /// (暂停 ↔ 继续); the title is its accessibility label and tooltip.
    private struct ChromeAction {
        let id: String
        let title: String
        let symbol: String
        var disabled = false
        let perform: () -> Void
    }

    private var cameraActions: [ChromeAction] {
        [
            ChromeAction(id: "pause", title: paused ? "继续星图转动" : "暂停星图转动", symbol: paused || reduceMotion ? "play" : "pause",
                         disabled: reduceMotion) { paused.toggle() },
            ChromeAction(id: "left", title: "向左旋转星图", symbol: "arrow.counterclockwise") { yaw -= 0.25 },
            ChromeAction(id: "right", title: "向右旋转星图", symbol: "arrow.clockwise") { yaw += 0.25 },
            ChromeAction(id: "out", title: "缩小星图", symbol: "minus", disabled: zoom <= 0.7) { zoom = max(0.7, zoom - 0.15) },
            ChromeAction(id: "in", title: "放大星图", symbol: "plus", disabled: zoom >= 1.6) { zoom = min(1.6, zoom + 0.15) },
            // A point in brackets — recentre the view — not the curved arrow the page's 撤销 means.
            ChromeAction(id: "reset", title: "复位星图", symbol: "dot.viewfinder") { yaw = 0; tilt = 0.52; zoom = 1; elapsed = 0; motionStart = Date() }
        ]
    }

    private var controls: some View {
        let actions = cameraActions
        return HStack(spacing: 0) {
            ForEach(actions, id: \.id) { action in
                control(action, flush: action.id == actions.last?.id)
            }
        }
        .fixedSize()
        .opacity(showsCamera ? 1 : 0)
    }

    @ViewBuilder private func control(_ action: ChromeAction, flush: Bool = false) -> some View {
        let button = Button(action: action.perform) {
            Image(systemName: action.symbol).font(.system(size: 11))
        }
        .buttonStyle(GlyphButtonStyle(tint: theme.ink3, flush: flush ? .trailing : nil))
        .disabled(action.disabled).accessibilityLabel(action.title).help(action.title)
        // ImageRenderer cannot draw native focus bridges.
        if staticRender { button } else { button.focused($chromeFocus, equals: action.id) }
    }
}

private extension View {
    /// Legibility on the sky without a chip: the text's own silhouette in the ground colour,
    /// twice, so the dust stops a point short of every letter.
    func groundHalo(_ ground: Color) -> some View {
        shadow(color: ground, radius: 1).shadow(color: ground, radius: 1.5)
    }
}
