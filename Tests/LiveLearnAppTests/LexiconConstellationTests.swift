import Foundation
import CoreGraphics
import Testing
import CloudEngine
@testable import LiveLearnApp

struct LexiconConstellationTests {
    @Test func selectionFindsLaterPagesAndInvalidMappingsRemainActionable() {
        let items = VocabularyLibrary(hotWords: (0..<245).map { "term-\($0)" }).items
        #expect(LexiconConstellation.page(containing: items[244].id, in: items) == 2)
        #expect(LexiconConstellation.page(containing: items[120].id, in: items) == 1)
        #expect(LexiconConstellation.page(containing: "missing", in: items) == nil)
        let invalid = VocabularyItem(kind: .glossary, raw: "missing translation")
        #expect(LexiconConstellation.detail(for: invalid) == "译法缺失，请编辑")
        #expect(LexiconConstellation.detail(for: .init(kind: .hotWord, raw: "LiveLearn")) == "热词 · 辅助语音识别")
    }

    @Test func searchingAndReorderingDoNotMoveTermCoordinates() {
        let library = VocabularyLibrary(hotWords: ["LiveLearn", "语音识别", "WhisperKit"])
        let original = LexiconConstellation.nodes(library.items, page: 0)
        let filtered = LexiconConstellation.nodes(library.items.filter { $0.source == "语音识别" }, page: 0)
        let reversed = LexiconConstellation.nodes(library.items.reversed(), page: 0)
        #expect(filtered.first?.position == original[1].position)
        #expect(reversed.first?.position == original.last?.position)
    }

    @Test func everyTermIsReachableAcrossBoundedPages() {
        let items = VocabularyLibrary(hotWords: (0..<503).map { "term-\($0)" }).items
        let pages = (0..<LexiconConstellation.pageCount(items.count)).map { LexiconConstellation.nodes(items, page: $0) }
        #expect(pages.allSatisfy { $0.count <= LexiconConstellation.pageSize })
        #expect(pages.flatMap { $0.map(\.id) } == items.map(\.id))
        #expect(LexiconConstellation.nodes(items, page: 999).map(\.id) == pages.last?.map(\.id))
        #expect(LexiconConstellation.nodes([], page: -10).isEmpty)
    }

    @Test func projectionStaysFiniteAtSupportedCameraLimits() {
        let items = VocabularyLibrary(hotWords: (0..<120).map { "词汇-\($0)" }).items
        for size in [CGSize(width: 450, height: 260), CGSize(width: 1400, height: 900)] {
            for tilt in [0.18, 1.05] {
                for zoom in [0.7, 1.6] {
                    for node in LexiconConstellation.nodes(items, page: 0) {
                        let projected = LexiconConstellation.project(node.position, size: size, yaw: 12, tilt: tilt, zoom: zoom)
                        #expect(projected.point.x.isFinite && projected.point.y.isFinite && projected.depth.isFinite)
                    }
                }
            }
        }
    }

    @Test func rotatingAndZoomingReallyChangeProjection() {
        let point = LexiconConstellation.Point(x: 0.7, y: 0.1, z: 0.2)
        let size = CGSize(width: 900, height: 600)
        let baseline = LexiconConstellation.project(point, size: size, yaw: 0, tilt: 0.5, zoom: 1)
        let rotated = LexiconConstellation.project(point, size: size, yaw: 0.5, tilt: 0.5, zoom: 1)
        let zoomed = LexiconConstellation.project(point, size: size, yaw: 0, tilt: 0.5, zoom: 1.6)
        #expect(baseline.point != rotated.point)
        #expect(abs(zoomed.point.x - size.width / 2) > abs(baseline.point.x - size.width / 2))
    }
}
