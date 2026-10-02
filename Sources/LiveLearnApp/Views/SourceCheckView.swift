import SwiftUI

/// The 音源检查 window. Round 12: the same near-black ground and type as the source popover it
/// is opened from — a `LLFont.title` title, the outcome as a 15/500 line (brick when the source
/// needs attention) over an `ink2` sentence, facts behind a 详细信息 word that opens with the
/// paper menu's chevron — and only text actions (重新检查, 关闭), no outlined or filled pills.
/// While listening the window says so in words; there is no spinner (§2).
struct SourceCheckView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("音源检查").font(LLFont.title).foregroundStyle(theme.ink)
                .gesture(WindowDragGesture())
            if model.isCheckingSource {
                Text("正在听取音源…").font(LLFont.body).foregroundStyle(theme.ink2)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            } else if let report = model.sourceCheckReport {
                SourceCheckOutcome(report: report, showDetails: $showDetails)
            } else {
                Text("检查所选音源能否正常收到声音。")
                    .font(LLFont.body).foregroundStyle(theme.ink2)
            }
            HStack {
                if !model.isCheckingSource {
                    Button("重新检查") { model.runSourceCheck() }
                        .buttonStyle(TextButtonStyle(flush: true))
                        .disabled(model.isActive || !model.hasSource)
                }
                Spacer()
                Button("关闭") {
                    model.cancelSourceCheck()
                    dismissWindow(id: "source-check")
                }
                .buttonStyle(TextButtonStyle(flush: true))
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(24).padding(.top, 16).frame(width: 480)
        .background(theme.ground)
        .ignoresSafeArea()
        .onDisappear { model.cancelSourceCheck() }
        .onChange(of: model.openSourceCheckRequest) { _, _ in showDetails = false }
    }
}

/// A finished check: the outcome as a 15/500 line (brick when the source needs attention) over
/// an `ink2` sentence, the advice's action directly under the sentence that asks for it, and
/// the facts behind 详细信息. Its own view so review renders can show every outcome; the blocks
/// stay separate children of the window's stack, 20 pt apart.
///
/// The action is the one thing a failed check asks of the reader, so it is the way forward
/// (`TextButtonStyle(strong:)`, 13/500 `ink` under the 13/400 `ink2` sentence) and it wears the
/// popover's ↗ when it opens another window. Below the disclosure, as it was, it read as body
/// text and sat under the details box instead of under its sentence.
struct SourceCheckOutcome: View {
    let report: SourceCheck.Report
    @Binding var showDetails: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
            Text(report.title).font(LLFont.heading)
                .foregroundStyle(report.outcome == .failed ? theme.brick : theme.ink)
            Text(report.summary).font(LLFont.body).lineSpacing(LLLeading.body).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let action = report.advice?.action {
                Button { model.perform(action) } label: {
                    HStack(spacing: 5) {
                        Text(action.label)
                        if Self.leavesWindow(action) {
                            Image(systemName: "arrow.up.right").font(.system(size: 9)).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(TextButtonStyle(flush: true, strong: true))
                .accessibilityLabel(action.label)
            }
        }
        if !report.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { showDetails.toggle() } label: {
                    HStack(spacing: 3) {
                        Text("详细信息").font(LLFont.label)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .semibold))
                            .rotationEffect(.degrees(showDetails ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(TextButtonStyle(tint: theme.ink3, flush: true))
                // The disclosure the system group used to announce, said in words.
                .accessibilityLabel("详细信息")
                .accessibilityValue(showDetails ? "已展开" : "已收起")
                if showDetails {
                    HuggingScrollBox(cap: 100) {
                        detailLines.hidden().accessibilityHidden(true)
                        ScrollContainer { detailLines }
                    }
                }
            }
        }
    }

    private var detailLines: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
            ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(LLFont.label).foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LLMetrics.space(1))
    }

    /// Whether the remedy opens another window (System Settings, Settings, Finder) and so wears
    /// the ↗ of the popover's engine link; 重新选择麦克风 acts in place.
    private static func leavesWindow(_ action: RecoveryAction) -> Bool {
        switch action {
        case .reselectMicrophone: return false
        case .openMicrophoneSettings, .openAudioCaptureSettings, .openLocalModels, .openEngineSettings, .openSessionsFolder:
            return true
        }
    }
}

/// The details box: as tall as its lines up to `cap`, then `cap` with the lines scrolling inside
/// (a fixed 100 pt box left a 60 pt void under two short lines). The first subview is a hidden
/// copy of the lines that only sets the height; the second, the scroll container, is placed at
/// that height. A scroll view alone takes whatever height it is offered, and a `ViewThatFits`
/// picks its first child whenever the window sizes itself to its content, so the lines have to
/// be measured.
struct HuggingScrollBox: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let lines = subviews.first else { return .zero }
        // An unbounded width (a max-size probe) is answered like no width at all, with the
        // lines' own: a layout never reports an infinite size.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let natural = lines.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? natural.width, height: min(natural.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
