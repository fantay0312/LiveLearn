import Foundation
import AudioDomain
import CaptionDomain
import SessionDomain

/// One row of the reading column. Built once per caption change in `AppModel`, so a view body
/// never walks the whole transcript. The source tag is set only where the lane differs from the
/// previous row (a single lane's run of sentences is not re-labelled on every line).
struct TranscriptRow: Identifiable, Equatable {
    let item: CaptionItem
    let tag: String?
    var id: String { item.id }
}

/// Tail placeholder for a lane that is running but has no open sentence.
struct ListeningRowModel: Identifiable, Equatable {
    let laneID: String
    /// nil when a single lane is already labelled by the row above.
    let tag: String?
    let text: String
    /// True while audio is arriving (solid dot); false while waiting (breathing dot).
    let live: Bool
    var id: String { "listening-\(laneID)" }
}

/// What the overlay shows for one lane: the current sentence, the one before it, and the most
/// recent gap, so the overlay body is O(1) per lane.
struct LaneTail: Equatable {
    var current: CaptionSegment?
    var previous: CaptionSegment?
    var earlier: CaptionSegment?
    var lastGap: CaptionGap?
}
