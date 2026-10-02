import SwiftUI

/// The one axis of the records page (round 12): the timestamp gutter and the measure form a
/// block, and everything on the page — the masthead, the sentences, the gap rules, the empty
/// state's opening line and the horizon transport under them — hangs from that block's two
/// edges and its text column.
///
/// The block is centred in whatever width the page has, never closer than 32 pt to either edge.
/// With the directory closed that puts it in the middle of the window instead of leaving
/// ~420 pt of black on the right; with it open, the list and the text sit in balance. The only
/// input is the content width, so opening or closing the directory moves the block in the same
/// transaction as the directory's own 240 ms width change.
enum ReadingColumn {
    /// Timestamp gutter + measure: from the left edge of the timestamps' column to the right rag.
    static let block = LLMetrics.gutterWidth + LLMetrics.measure
    /// Where the text starts inside the block: the gutter, the 2 pt now-bar slot and its gap.
    static let textInset = LLMetrics.gutterWidth + nowSlot + LLMetrics.space(3)
    /// The 2 pt "此刻" mark's slot, which also carries the time thread's points.
    static let nowSlot: CGFloat = 2
    /// The least room left on either side of the block.
    static let margin = LLMetrics.space(6)
    /// The air between two rows of the page (sentences, a gap), which the time thread crosses.
    static let rowSpacing = LLMetrics.space(6)

    /// The block's leading edge in a page `width` points wide.
    static func leading(in width: CGFloat) -> CGFloat {
        max(margin, ((width - block) / 2).rounded(.down))
    }

    /// The block's width in a page `width` points wide: the full block, or what is left between
    /// the leading edge and the trailing margin in a narrow window.
    static func width(in width: CGFloat) -> CGFloat {
        max(0, min(block, width - leading(in: width) - margin))
    }
}
