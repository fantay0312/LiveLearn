import AppKit
import Foundation
import SwiftUI
import Testing
import CaptionDomain
import SessionDomain
import SessionStorage
@testable import LiveLearnApp

/// Round 12 records: the reading block's one axis, how a record names itself in the rail and
/// the masthead, and the time thread in the transcript gutter. How the page looks is reviewed
/// from the `--render-main-previews` / `--render-living-controls` renders.
@MainActor
struct Round12RecordsTests {
    /// The gutter + measure block is centred in whatever width the page has, and never comes
    /// closer than 32 pt to either edge: with the directory closed at the default window it
    /// sits in the middle of the window; in the narrowest page (960 with the directory open) it
    /// keeps both margins and gives up measure instead.
    @Test func readingBlockIsCentredAndKeepsItsMargins() {
        #expect(ReadingColumn.block == 712 && ReadingColumn.textInset == 86)
        #expect(ReadingColumn.leading(in: 1180) == 234 && ReadingColumn.width(in: 1180) == 712)
        for window in [CGFloat(960), 1180, 1440, 1920] {
            for open in [false, true] {
                let page = window - (open ? MainWindowLayout.historyWidth(windowWidth: window) : 0)
                let leading = ReadingColumn.leading(in: page)
                let width = ReadingColumn.width(in: page)
                #expect(leading >= ReadingColumn.margin, "\(window) \(open)")
                #expect(page - leading - width >= ReadingColumn.margin, "\(window) \(open)")
                if page >= ReadingColumn.block + 2 * ReadingColumn.margin {
                    #expect(width == ReadingColumn.block, "\(window) \(open)")
                    // Centred to the point: the two margins differ by at most the rounding.
                    #expect(abs((page - leading - width) - leading) <= 1, "\(window) \(open)")
                }
            }
        }
        // The narrowest page still reads: 960 − 264 leaves 632 pt of block.
        #expect(ReadingColumn.width(in: 960 - 264) == 632)
    }

    /// The rail names a record by what was said: the first translated sentence, then the first
    /// recognised one when nothing was translated, then nothing (the row falls back to its time).
    @Test func recordHeadlineIsTheFirstThingThatWasSaid() throws {
        let archive = SessionArchive(snapshot: SampleData.runningSnapshot(), title: "Release review", startedAt: Date(),
                                     outcome: .completed, appVersion: "test")
        let record = SessionRecord(archive: archive, saved: false)
        #expect(RecordFacts.headline(record) == "在动生产环境之前，我们先看看日志到底在说什么。")

        var untranslated = archive
        untranslated.items = archive.items.map { item in
            guard case .segment(var segment) = item else { return item }
            segment.translation = nil
            return .segment(segment)
        }
        #expect(RecordFacts.headline(SessionRecord(archive: untranslated, saved: false))
                == "Before we touch anything in production, let's look at what the logs are actually saying.")

        // A later translation still wins over an earlier untranslated sentence.
        var late = untranslated
        let lastTranslated = try #require(archive.items.lastIndex { if case .segment(let s) = $0 { return s.translation != nil }; return false })
        late.items[lastTranslated] = archive.items[lastTranslated]
        guard case .segment(let expected) = archive.items[lastTranslated] else { Issue.record("not a segment"); return }
        #expect(RecordFacts.headline(SessionRecord(archive: late, saved: false)) == expected.translation?.text)

        var empty = archive
        empty.items = []
        #expect(RecordFacts.headline(SessionRecord(archive: empty, saved: false)) == nil)
    }

    /// The rail's second line leads with the time and names only the sources, so it fits the
    /// rail without an ellipsis; the masthead's summary keeps the direction.
    @Test func railMetaLeadsWithTheTimeAndTheMastheadKeepsTheDirection() throws {
        var components = DateComponents()
        components.year = 2025; components.month = 12; components.day = 31; components.hour = 17; components.minute = 5
        let started = try #require(Calendar.current.date(from: components))
        let archive = SessionArchive(snapshot: SampleData.runningSnapshot(), title: "Release review", startedAt: started,
                                     outcome: .completed, appVersion: "test")
        let record = SessionRecord(archive: archive, saved: false)
        let meta = RecordFacts.meta(record)
        #expect(meta.hasPrefix("17:05 · \(record.segmentCount) 句 · "))
        #expect(!meta.contains("→"))
        #expect(RecordFacts.detail(record).contains("→"))
        // Another year's record carries its year and its weekday.
        #expect(RecordFacts.masthead(record) == "2025年12月31日 周三 17:05")
    }

    /// The time thread: a final sentence leaves a small point in the now bar's slot, an open one
    /// carries the bar there instead — but only while the session still writes the page: in a
    /// finished record a sentence left open is set like the rest, with a point and no bar.
    /// Measured as the lit run in the slot's column: a point is a couple of pixels tall, the bar
    /// spans the sentence.
    @Test func finalSentencesLeaveAPointInTheNowSlotAndTheOpenOneCarriesTheBar() throws {
        let model = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "LiveLearn.testing.r12-thread.\(UUID().uuidString)")!),
                             preview: SampleData.runningSnapshot())
        let segments = model.transcriptRows.compactMap { row -> CaptionSegment? in
            if case .segment(let s) = row.item { return s }
            return nil
        }
        let final = try #require(segments.first { $0.presentationState == .final })
        let open = try #require(segments.last { $0.presentationState != .final && $0.presentationState != .frozen })

        func litRows(_ segment: CaptionSegment, _ writing: SegmentRow.Writing = .live) throws -> Int {
            let view = ThemedRoot(forced: .stellar) {
                SegmentRow(segment: segment, sourceTag: nil, serif: false, writing: writing, threadBelow: false)
                    .frame(width: ReadingColumn.block)
                    .background(Color(hex: 0x030405))
                    .environment(\.staticRender, true)
            }
            let image = try renderedImage(view, scale: 2)
            let samples = try canonicalSamples(image)
            // The slot is 2 pt at the gutter's right edge: pixels 144…147 at 2×.
            let x = Int(LLMetrics.gutterWidth * 2) + 1
            return (0..<image.height).filter { y in
                let i = (y * image.width + x) * 4
                return Int(samples[i]) + Int(samples[i + 1]) + Int(samples[i + 2]) > 3 * 24
            }.count
        }
        let point = try litRows(final)
        #expect(point >= 1 && point <= 4, "final: \(point) lit rows")
        #expect(try litRows(open) > 20, "open: the now bar spans the sentence")
        #expect(try litRows(open, .paused) > 20, "paused: the open sentence keeps its bar")
        let ended = try litRows(open, .ended)
        #expect(ended >= 1 && ended <= 4, "ended: \(ended) lit rows")
    }

    /// A live page pinned to its tail rests its open sentence on the horizon: the now bar ends
    /// one bottom fade (24) plus the column's 12 pt foot above the page's lower edge, where the
    /// horizon's rule is drawn — the tail does not also take the rows' 32 pt spacing.
    @Test func liveLineRestsThirtySixPointsAboveTheHorizon() throws {
        let model = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "LiveLearn.testing.r12-tail.\(UUID().uuidString)")!),
                             preview: SampleData.runningSnapshot())
        let page = try TranscriptPage(model, height: 420)
        let air = try page.height - page.nowBarBottom()
        #expect(abs(air - 36) <= 2, "now bar ends \(air) pt above the horizon")
    }

    /// The masthead leaves a live page as one unit: a page followed 24 pt past its start holds
    /// only ground above its first sentence — no ghost of the title, no facts under a sliced
    /// one — while a record opened from its start keeps its masthead in full ink.
    @Test func mastheadIsWholeAtRestAndGoneOnceThePageMovesPastIt() throws {
        let live = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "LiveLearn.testing.r12-masthead.\(UUID().uuidString)")!),
                            preview: SampleData.runningSnapshot())
        // Tall enough for the whole page, which then rests at its start: where does it end?
        let whole = try TranscriptPage(live, height: 1600)
        let end = try whole.nowBarBottom()
        try #require(end < whole.height - 40, "the page fits the tall render")
        // Pinned to its tail the bar ends 36 pt above the lower edge (the test above), so at this
        // height the page has moved 24 pt: the masthead's top is 8 pt below the page's edge.
        let followed = try TranscriptPage(live, height: end + 36 - 24)
        let ghost = followed.brightest(y: 0..<48)
        #expect(ghost <= 3 * 24, "above the first sentence: brightest channel sum \(ghost)")

        let reader = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "LiveLearn.testing.r12-masthead-record.\(UUID().uuidString)")!),
                              preview: .empty())
        var finished = SampleData.runningSnapshot()
        finished.state = .completed
        reader.receive(finished)
        reader.receive(.empty())
        reader.requestRecords()
        try #require(reader.isViewingRecord)
        // Longer than the page, so only its resting place keeps the masthead at the top inset.
        let record = try TranscriptPage(reader, height: 420)
        let title = record.brightest(y: TranscriptView.topInset..<(TranscriptView.topInset + 32))
        #expect(title >= 3 * 200, "the record's title: brightest channel sum \(title)")
    }

    /// Opt-in review renders of the records states the preview fixtures do not cover (a dark
    /// finished record, the horizon on the vocabulary page, paused, Increase Contrast, an
    /// unmatched search, a failed session on paper in the smallest window):
    /// `LIVELEARN_R12_GALLERY=<dir> swift test --filter Round12RecordsTests/gallery`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_R12_GALLERY"] != nil))
    func gallery() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_R12_GALLERY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ view: some View, _ name: String, theme: LLTheme = .stellar, contrast: ColorSchemeContrast = .standard,
                  size: CGSize = LLMetrics.defaultWindow) throws {
            let root = ThemedRoot(forced: theme) { view }
                .environment(\._colorSchemeContrast, contrast)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
                .environment(\.staticRender, true)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(size)
            let image = try #require(renderer.cgImage)
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        let suite = "LiveLearn.testing.r12-records-gallery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func model(_ snapshot: SessionSnapshot) -> AppModel {
            let model = AppModel(settings: settings, preview: snapshot)
            for n in 1...3 {
                var record = SampleData.runningSnapshot(dual: n == 2, includeGap: n != 1)
                record.sessionID = "gallery-record-\(n)"
                record.captions.sessionID = record.sessionID
                record.state = .completed
                record.elapsedNs = Int64(n * 124) * 1_000_000_000
                model.receive(record)
            }
            model.receive(snapshot)
            return model
        }
        let idle = model(.empty())
        idle.requestRecords()
        if let record = idle.records.last { idle.showRecord(record) }
        for open in [true, false] {
            try save(RootView(previewHistoryVisible: open).environment(idle), "record-dark-\(open ? "open" : "closed")")
        }
        try save(RootView(previewHistoryVisible: true).environment(idle), "record-dark-minimum", size: LLMetrics.minWindow)
        try save(RootView(previewHistoryVisible: true).environment(idle), "record-dark-contrast", contrast: .increased)
        var paused = SampleData.runningSnapshot(dual: true)
        paused.state = .paused
        let pausedModel = model(paused)
        pausedModel.requestRecords()
        try save(RootView(previewHistoryVisible: true).environment(pausedModel), "paused-dual-dark")
        try save(RootView(previewHistoryVisible: false).environment(pausedModel), "paused-dual-light-minimum", theme: .wilds, size: LLMetrics.minWindow)
        let running = model(SampleData.runningSnapshot())
        running.requestVocabularyWindow()
        try save(RootView().environment(running), "vocabulary-live-dark")
        try save(SidebarView(width: 295, query: .constant("absent-term")).environment(idle).background(Color(hex: 0x030405)),
                 "rail-no-match", size: CGSize(width: 295, height: 400))
        var failed = SessionSnapshot.empty()
        failed.state = .failed
        failed.failure = "系统音频录制未获授权。请在系统设置中允许 LiveLearn，然后重新开始。"
        let failedModel = model(failed)
        failedModel.requestRecords()
        try save(RootView(previewHistoryVisible: true).environment(failedModel), "failed-dark")
        try save(RootView(previewHistoryVisible: true).environment(failedModel), "failed-light-minimum", theme: .wilds, size: LLMetrics.minWindow)
    }
}

/// The transcript alone on the stellar ground, 900 pt wide, drawn by the offscreen path
/// (`RestingScroll`) at 2×, and read in points.
@MainActor
private struct TranscriptPage {
    static let width: CGFloat = 900
    let height: CGFloat
    let image: CGImage
    let samples: [UInt8]

    init(_ model: AppModel, height: CGFloat) throws {
        let view = ThemedRoot(forced: .stellar) {
            TranscriptView(width: Self.width)
                .frame(width: Self.width, height: height)
                .background(Color(hex: 0x030405))
                .environment(model)
                .environment(\.staticRender, true)
        }
        self.height = height
        image = try renderedImage(view, scale: 2)
        samples = try canonicalSamples(image)
    }

    private func sum(_ x: Int, _ y: Int) -> Int {
        let i = (y * image.width + x) * 4
        return Int(samples[i]) + Int(samples[i + 1]) + Int(samples[i + 2])
    }

    /// Where the open sentence's now bar ends, from the top: the lowest lit pixel in its slot,
    /// 2 pt at the gutter's right edge of the centred block.
    func nowBarBottom() throws -> CGFloat {
        let x = Int((ReadingColumn.leading(in: Self.width) + LLMetrics.gutterWidth) * 2) + 1
        let lit = (0..<image.height).filter { sum(x, $0) > 3 * 96 }
        return CGFloat(try #require(lit.max(), "the open sentence carries the now bar") + 1) / 2
    }

    /// The brightest pixel (sum of channels) across the reading block in a band of the page.
    func brightest(y band: Range<CGFloat>) -> Int {
        let leading = ReadingColumn.leading(in: Self.width)
        let xs = Int(leading * 2)..<Int((leading + ReadingColumn.width(in: Self.width)) * 2)
        let ys = Int(band.lowerBound * 2)..<min(image.height, Int(band.upperBound * 2))
        return ys.lazy.flatMap { y in xs.lazy.map { sum($0, y) } }.max() ?? 0
    }
}
