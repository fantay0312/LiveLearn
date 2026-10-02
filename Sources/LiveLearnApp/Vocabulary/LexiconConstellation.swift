import Foundation
import CoreGraphics
import CloudEngine
import ParticleMath

/// Stable coordinates are derived from identity, never from a term's apparent importance.
/// Paging bounds rendering work; the complete library remains searchable and editable.
enum LexiconConstellation {
    static let pageSize = 120

    struct Point: Equatable {
        var x: Double
        var y: Double
        var z: Double
    }

    struct Node: Identifiable {
        let item: VocabularyItem
        let position: Point
        var id: String { item.id }
    }

    struct Projection {
        let point: CGPoint
        let depth: Double
    }

    struct Dust {
        let position: Point
        /// The grain's width in points at zoom 1 (0.52–1.76): silver grains finer than this
        /// dissolve into the black at the alphas the field uses.
        let radius: Double
        /// 0…1, before the depth cue.
        let brightness: Double
        /// About one grain in twenty-three (one in seventeen outside the nucleus) is a brighter
        /// pearl grain; the rest are neutral silver. The dust never borrows the term hues (ice,
        /// gold), so those keep meaning a word.
        let pearl: Bool
    }

    static func fraction(_ text: String, salt: UInt64 = 0) -> Double {
        StableHash.fraction(text, salt: salt)
    }

    static func nodes(_ items: [VocabularyItem], page: Int) -> [Node] {
        let start = min(max(0, page), pageCount(items.count) - 1) * pageSize
        return items.dropFirst(start).prefix(pageSize).map { item in
            let radius = 0.24 + sqrt(fraction(item.id)) * 0.7
            let angle = fraction(item.id, salt: 71) * .pi * 2
            return Node(item: item, position: Point(x: cos(angle) * radius,
                y: (fraction(item.id, salt: 137) - 0.5) * 0.44,
                z: sin(angle) * radius))
        }
    }

    static func pageCount(_ count: Int) -> Int { max(1, (max(0, count) + pageSize - 1) / pageSize) }

    static func page(containing id: String?, in items: [VocabularyItem]) -> Int? {
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return index / pageSize
    }

    static func detail(for item: VocabularyItem) -> String {
        if !item.isValid { return item.kind == .glossary ? "译法缺失，请编辑" : "热词为空，请编辑" }
        return item.kind == .hotWord ? "热词 · 辅助语音识别" : item.target
    }

    /// Projects a field position into `size`, the area the field is fitted to (the map passes its
    /// sky above the floating count and camera row). At the resting tilt the disc's near half
    /// projects higher and larger than its far half — the dust spans about −0.70 … +0.57 of the
    /// scale around the nucleus — so the nucleus sits 0.056 × scale under the area's middle, which
    /// leaves the same clear margin above and below the dust.
    static func project(_ point: Point, size: CGSize, yaw: Double, tilt: Double, zoom: Double) -> Projection {
        let x = point.x * cos(yaw) - point.z * sin(yaw)
        let z = point.x * sin(yaw) + point.z * cos(yaw)
        let y = point.y * cos(tilt) - z * sin(tilt)
        let depth = point.y * sin(tilt) + z * cos(tilt)
        let perspective = 2.8 / (2.8 - depth * 0.3)
        let scale = min(size.width * 0.43, size.height * 0.66) * min(1.6, max(0.7, zoom))
        return Projection(point: CGPoint(x: size.width * 0.5 + (x * 0.97 + y * 0.19) * scale * perspective,
                                          y: size.height * 0.5 + scale * 0.056 + (y * 0.97 - x * 0.19) * scale * perspective),
                          depth: depth)
    }

    /// Where a projected depth sits between the back of the field (0) and the front (1). Term
    /// positions reach ±0.97, so the range covers every star at any tilt. Size and brightness
    /// follow this share as a depth cue only — never as a claim about the word.
    static func depthShare(_ depth: Double) -> Double {
        min(1, max(0, (depth + 0.97) / 1.94))
    }

    /// A fixed, original spiral distribution. Decorative particles are not vocabulary entries.
    /// A quarter of the grains form a round nucleus — the dust's brightest region, made of grains
    /// rather than of a lifted black, and still dimmer than every term: its grains spread over
    /// its radius instead of stacking into a white clump at the centre, carry no pearl, and stop
    /// at a mid silver. A ninth are strewn loosely over the disc; the rest trail in two loose
    /// arms whose density and light fall off from the centre.
    static let dust: [Dust] = (0..<1800).map { index in
        let key = "dust-\(index)"
        let nucleus = index % 4 == 0
        let loose = !nucleus && index % 9 == 1
        let radius = nucleus ? pow(fraction(key), 1.1) * 0.30 : pow(fraction(key), 0.7) * 1.13
        let arm = Double(index % 2) * .pi
        let spread = nucleus || loose ? .pi * 2 : 0.55
        let angle = arm + radius * 4.2 + (fraction(key, salt: 42) - 0.5) * spread
        let lift = fraction(key, salt: 87)
        // The nucleus is a bulge (as thick as it is wide, so its smallest radii do not stand up
        // as a streak); the disc keeps its thin, slightly flaring slab.
        let thickness = nucleus ? radius * 0.9 : 0.12 + 0.08 * radius
        let fade = 1 - 0.4 * radius / 1.13
        return Dust(position: Point(x: cos(angle) * radius,
                                    y: (fraction(key, salt: 24) - 0.5) * thickness,
                                    z: sin(angle) * radius),
                    radius: (nucleus ? 0.65 : 0.52) + fraction(key, salt: 113) * 1.24,
                    brightness: nucleus ? 0.40 + lift * 0.35 : (0.25 + lift * 0.75) * fade * (loose ? 0.6 : 1),
                    pearl: !nucleus && index % 17 == 0)
    }

    // MARK: Binary stars

    /// Centre-to-centre distance of a binary star's two points, in points: close enough to read
    /// as one star (under 4 pt), far enough that the pair never merges into a blot.
    static let binarySeparation: CGFloat = 3.6
    /// The companion (the translation) is the lesser point of the pair.
    static let companionScale: CGFloat = 0.75
    /// The companion's direction in a static mark (the list gutter, the rail): up and to the
    /// right, −30°.
    static let markCompanionAngle: CGFloat = -.pi / 6

    /// The companion's direction on the map: fixed per term and turned with the camera's yaw, so
    /// the pair turns with the field instead of orbiting on a clock of its own.
    static func companionAngle(for id: String, yaw: Double) -> Double {
        fraction(id, salt: 211) * .pi * 2 + yaw
    }

    // MARK: Labels

    /// Which side of its star a name was set on.
    enum LabelSide: Equatable { case right, left, above, below }

    /// One place a name may take: a side and, beside the star, the name's height stepped a few
    /// points off the point's (−1 up, +1 down), the way a printed chart slips a name past a
    /// neighbour instead of moving it to another side.
    struct LabelSlot: Equatable {
        let side: LabelSide
        var nudge = 0
    }

    struct PlacedLabel {
        let rect: CGRect
        let slot: LabelSlot
        var side: LabelSide { slot.side }
    }

    struct LabelRequest {
        let id: String
        /// The star's point.
        let anchor: CGPoint
        let size: CGSize
        /// A binary star's companion point: a neighbour's pair is kept clear as a whole.
        var companion: CGPoint? = nil
    }

    /// Gap between a star's point and the near edge of its name.
    static let labelGap: CGFloat = 8
    /// How far a stepped name moves off its star's height.
    static let labelNudge: CGFloat = 5
    /// How far every other star's points stay from a name: beside it twice `labelGap`, above and
    /// below it `labelGap` plus a front core's width, so wherever a clear place exists a
    /// neighbour's point ends at least half as far again from the name as its own star (8 pt) —
    /// at 10 pt, two names hung above and below a pair of stars 6 pt apart still read as each
    /// other's.
    static let neighbourClearance = CGSize(width: 16, height: 12)
    /// At most this many names on one page of the map. At or under it, a name is never dropped:
    /// a small library is exactly where every star must be identifiable.
    static let labelLimit = 26
    /// Over `labelLimit` stars, one name per this much sky (pt²), so a small window is not
    /// papered with names: about 18 at the minimum window, the full `labelLimit` from the default.
    static let skyPerName: CGFloat = 16_000

    /// The places a name tries, in order: beside its star to the right, then to the left, then
    /// the four stepped variants beside it; above or below only when all six collide — a name
    /// hung centred under its point reads as a map pin, not as that star's name.
    static let slots: [LabelSlot] = [
        LabelSlot(side: .right), LabelSlot(side: .left),
        LabelSlot(side: .right, nudge: -1), LabelSlot(side: .right, nudge: 1),
        LabelSlot(side: .left, nudge: -1), LabelSlot(side: .left, nudge: 1),
        LabelSlot(side: .above), LabelSlot(side: .below)
    ]

    /// Sets names beside their stars as on a printed chart: each name takes the first of `slots`
    /// that stays inside `bounds`, clear of the names already set, of the `reserved` areas (the
    /// selected star and its annotation, the nucleus) and of every other star's points — both
    /// points of a binary, counted within `neighbourClearance` of the name — so a name never ends
    /// nearer a neighbour's point than its own. A name keeps its `previous` slot beside its star
    /// while that stays clear, so names do not hop sides as the field turns.
    ///
    /// Requests come in priority order, front to back. Up to `labelLimit` requests every star
    /// gets a name even where nothing is clear, on the side that overlaps least. Beyond it,
    /// names are offered spread over the sky (`spread`), set only where clear, and capped at
    /// one per `skyPerName` of `bounds` (at least six, never more than `labelLimit`).
    static func placeLabels(_ requests: [LabelRequest], reserved: [CGRect], bounds: CGRect,
                            previous: [String: LabelSlot] = [:]) -> [String: PlacedLabel] {
        let keepAll = requests.count <= labelLimit
        let offered = keepAll ? requests : spread(requests, bounds: bounds, named: Set(previous.keys))
        let limit = keepAll ? labelLimit : min(labelLimit, max(6, Int(bounds.width * bounds.height / skyPerName)))
        var occupied = reserved
        var placed: [String: PlacedLabel] = [:]
        for request in offered {
            if placed.count >= limit { break }
            func overlap(_ rect: CGRect) -> CGFloat {
                let padded = rect.insetBy(dx: -6, dy: -2)
                var area: CGFloat = 0
                for other in occupied where other.intersects(padded) {
                    let shared = other.intersection(padded)
                    area += shared.width * shared.height
                }
                let near = rect.insetBy(dx: -neighbourClearance.width, dy: -neighbourClearance.height)
                for star in requests where star.id != request.id {
                    if near.contains(star.anchor) { area += 36 }
                    if let companion = star.companion, near.contains(companion) { area += 36 }
                }
                let inside = rect.intersection(bounds)
                area += (rect.width * rect.height - (inside.isNull ? 0 : inside.width * inside.height)) * 4
                return area
            }
            // Only a place beside the star is kept: a name pushed above or below returns beside
            // its star as soon as a side clears.
            let kept = previous[request.id].flatMap { $0.side == .right || $0.side == .left ? $0 : nil }
            let order = (kept.map { [$0] } ?? []) + slots.filter { $0 != kept }
            let candidates = order.map { PlacedLabel(rect: labelRect(request, slot: $0), slot: $0) }
            let chosen: PlacedLabel?
            if let clear = candidates.first(where: { overlap($0.rect) == 0 }) {
                chosen = clear
            } else if keepAll {
                chosen = candidates.min { overlap($0.rect) < overlap($1.rect) }
            } else {
                chosen = nil
            }
            if let chosen {
                placed[request.id] = chosen
                occupied.append(chosen.rect)
            }
        }
        return placed
    }

    /// The order names are offered in on a crowded page: `bounds` is cut into a 4 × 3 grid and
    /// every cell offers its first star, then every cell its second, then its third — never more
    /// — so the names spread over the whole sky instead of filling its densest band first. Within
    /// a cell a star named in the previous frame (`named`) comes first, then front to back.
    static func spread(_ requests: [LabelRequest], bounds: CGRect, named: Set<String>) -> [LabelRequest] {
        func cell(_ point: CGPoint) -> Int {
            let column = min(3, max(0, Int((point.x - bounds.minX) / max(1, bounds.width / 4))))
            let row = min(2, max(0, Int((point.y - bounds.minY) / max(1, bounds.height / 3))))
            return row * 4 + column
        }
        let ordered = requests.filter { named.contains($0.id) } + requests.filter { !named.contains($0.id) }
        var taken = [Int: Int]()
        var ranked: [(rank: Int, request: LabelRequest)] = []
        for request in ordered {
            let key = cell(request.anchor)
            let rank = taken[key, default: 0]
            taken[key] = rank + 1
            if rank < 3 { ranked.append((rank, request)) }
        }
        // A stable sort keeps the within-rank order: named first, then front to back.
        return ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.request)
    }

    /// The name's box in one slot: beside the star, centred on the point's height (stepped by
    /// `labelNudge` for a nudged slot); above or below it, centred on the point.
    static func labelRect(_ request: LabelRequest, slot: LabelSlot) -> CGRect {
        let p = request.anchor, w = request.size.width, h = request.size.height
        let y = p.y - h / 2 + CGFloat(slot.nudge) * labelNudge
        switch slot.side {
        case .right: return CGRect(x: p.x + labelGap, y: y, width: w, height: h)
        case .left: return CGRect(x: p.x - labelGap - w, y: y, width: w, height: h)
        case .above: return CGRect(x: p.x - w / 2, y: p.y - labelGap - h, width: w, height: h)
        case .below: return CGRect(x: p.x - w / 2, y: p.y + labelGap, width: w, height: h)
        }
    }
}
