import Foundation

public enum CaptionEffect: Sendable, Equatable {
    case segmentCreated(String)
    case segmentChanged(String)
    case translationChanged(String)
    case gapRecorded(String)
    case laneStateChanged(String)
    case laneFrozen(lane: String, providerEpoch: UInt64)
    case dropped(eventID: String, reason: DropReason)

    public enum DropReason: String, Sendable {
        case duplicateEvent
        case otherSession
        case staleProviderEpoch
        case staleRevision
        case finalizedSegment
        case staleTranslation
        case unknownSegment
        case malformed
    }
}

/// Deterministic, I/O-free caption merge. Same fixtures must pass on macOS and Windows.
///
/// Invariants (doc §11.3):
/// 1. Events from another session / lane / older provider epoch never merge in.
/// 2. A late translation for an older source revision never overwrites a newer one.
/// 3. Finalized text is never rewritten by partials; corrections are explicit and kept in history.
/// 4. Dedup by event id + segment id + time, never by text.
/// 5. Lanes never delete each other's identical sentences.
/// 6. Source final, translation final and "displayed long enough" are separate states.
public struct CaptionReducer: Sendable {
    public private(set) var snapshot: CaptionSnapshot
    private var index: [String: Int] = [:]           // segment key -> items index
    private var seen: [String: SeenSet] = [:]        // lane -> seen ids per epoch
    private var nextOrder = 0
    public var historyLimit = 8
    public var seenLimitPerEpoch = 4096
    /// Longer texts are truncated (with an ellipsis) so one runaway event cannot break layout.
    public var maxTextLength = 4000
    /// Events rejected by `validate` before touching any state, by reason (diagnostics).
    public private(set) var malformedCount = 0

    private struct SeenSet: Sendable {
        var epoch: UInt64
        var ids: Set<String> = []
        var ring: [String] = []
        var previous: (epoch: UInt64, ids: Set<String>)? = nil
    }

    public init(sessionID: String) {
        snapshot = CaptionSnapshot(sessionID: sessionID)
    }

    private static func key(lane: String, providerEpoch: UInt64, segmentID: String) -> String {
        "\(lane)/\(providerEpoch)/\(segmentID)"
    }

    // MARK: - Apply

    public mutating func apply(_ incoming: CaptionEvent) -> [CaptionEffect] {
        guard incoming.sessionID == snapshot.sessionID else {
            return [.dropped(eventID: incoming.eventID, reason: .otherSession)]
        }
        // Structural validation happens before the epoch table or the dedup cache is touched,
        // so a malformed event cannot advance an epoch or poison idempotency.
        if let reason = Self.validate(incoming) {
            malformedCount += 1
            return [.dropped(eventID: incoming.eventID, reason: reason)]
        }
        var event = incoming
        if let t = event.text, t.count > maxTextLength {
            event.text = String(t.prefix(maxTextLength)) + "…"
        }
        // Provider epoch gating (invariant 1).
        var effects: [CaptionEffect] = []
        let active = snapshot.activeProviderEpochs[event.laneID]
        if let active {
            if event.providerEpoch < active {
                return [.dropped(eventID: event.eventID, reason: .staleProviderEpoch)]
            }
            if event.providerEpoch > active {
                effects.append(contentsOf: freezeLane(event.laneID, upTo: event.providerEpoch))
            }
        } else {
            snapshot.activeProviderEpochs[event.laneID] = event.providerEpoch
            seen[event.laneID] = SeenSet(epoch: event.providerEpoch)
        }
        // Idempotency (invariant 4).
        if isDuplicate(event) {
            return effects + [.dropped(eventID: event.eventID, reason: .duplicateEvent)]
        }
        remember(event)

        switch event.type {
        case .sourceReplace, .sourceFinal:
            effects.append(contentsOf: applySource(event, isCorrection: false))
        case .sourceCorrection:
            effects.append(contentsOf: applySource(event, isCorrection: true))
        case .translationReplace, .translationFinal:
            effects.append(contentsOf: applyTranslation(event))
        case .laneGap:
            effects.append(contentsOf: applyGap(event))
        case .laneState:
            if let state = event.laneState {
                snapshot.laneStates[event.laneID] = state
                bump()
                effects.append(.laneStateChanged(event.laneID))
            }
        }
        return effects
    }

    // MARK: - Validation

    /// Returns a drop reason when the event cannot be applied safely: negative or inverted time
    /// range, negative revision, empty identifiers, or a type-specific required field missing.
    static func validate(_ e: CaptionEvent) -> CaptionEffect.DropReason? {
        if e.eventID.isEmpty || e.laneID.isEmpty { return .malformed }
        if let s = e.startNs, s < 0 { return .malformed }
        if let n = e.endNs, n < 0 { return .malformed }
        if let s = e.startNs, let n = e.endNs, n < s { return .malformed }
        if let r = e.revision, r < 0 { return .malformed }
        switch e.type {
        case .sourceReplace, .sourceFinal, .sourceCorrection:
            guard let seg = e.segmentID, !seg.isEmpty, e.text != nil, e.revision != nil else { return .malformed }
        case .translationReplace, .translationFinal:
            guard let refs = e.sourceRefs, !refs.isEmpty, e.text != nil else { return .malformed }
            if refs.contains(where: { $0.segmentID.isEmpty || $0.revision < 0 }) { return .malformed }
        case .laneGap:
            guard e.startNs != nil, e.endNs != nil else { return .malformed }
        case .laneState:
            guard let s = e.laneState, !s.isEmpty else { return .malformed }
        }
        return nil
    }

    // MARK: - Source

    private mutating func applySource(_ event: CaptionEvent, isCorrection: Bool) -> [CaptionEffect] {
        guard let segmentID = event.segmentID, let text = event.text, let revision = event.revision else {
            return [.dropped(eventID: event.eventID, reason: .malformed)]
        }
        let isFinal = event.type == .sourceFinal || (event.isFinal ?? false) || isCorrection
        let key = Self.key(lane: event.laneID, providerEpoch: event.providerEpoch, segmentID: segmentID)

        if let idx = index[key], case .segment(var seg) = snapshot.items[idx] {
            if seg.presentationState == .frozen {
                return [.dropped(eventID: event.eventID, reason: .finalizedSegment)]
            }
            if seg.sourceFinal && !isCorrection {
                // Invariant 3: partials (or repeated finals) do not rewrite finalized text.
                return [.dropped(eventID: event.eventID, reason: .finalizedSegment)]
            }
            if revision < seg.sourceRevision {
                return [.dropped(eventID: event.eventID, reason: .staleRevision)]
            }
            if revision == seg.sourceRevision && text == seg.sourceText && isFinal == seg.sourceFinal {
                return [.dropped(eventID: event.eventID, reason: .duplicateEvent)]
            }
            if isCorrection || (text != seg.sourceText && seg.sourceFinal) {
                seg.history.append(seg.sourceText)
                if seg.history.count > historyLimit { seg.history.removeFirst(seg.history.count - historyLimit) }
                seg.corrected = true
            }
            seg.sourceText = text
            seg.sourceRevision = revision
            seg.sourceFinal = isFinal
            seg.vocabularyCandidates = isFinal ? event.vocabularyCandidates : nil
            if let l = event.language { seg.sourceLanguage = l }
            if let s = event.startNs { seg.startNs = s }
            if let e = event.endNs { seg.endNs = e }
            if let q = event.timingQuality { seg.timingQuality = q }
            if var t = seg.translation, t.basedOnRevision < revision {
                t.isStale = true
                seg.translation = t
            }
            seg.presentationState = Self.presentation(for: seg)
            snapshot.items[idx] = .segment(seg)
            bump()
            return [.segmentChanged(seg.id)]
        }

        let seg = CaptionSegment(
            id: key,
            providerSegmentID: segmentID,
            laneID: event.laneID,
            captureEpoch: event.captureEpoch,
            providerEpoch: event.providerEpoch,
            sourceText: text,
            sourceRevision: revision,
            sourceLanguage: event.language,
            sourceFinal: isFinal,
            startNs: event.startNs ?? 0,
            endNs: event.endNs ?? (event.startNs ?? 0),
            timingQuality: event.timingQuality ?? .unknown,
            translation: nil,
            mergedIntoTranslation: nil,
            presentationState: .preview,
            corrected: isCorrection,
            order: nextOrder,
            history: [],
            incompleteReason: nil
        )
        var created = seg
        created.vocabularyCandidates = isFinal ? event.vocabularyCandidates : nil
        created.presentationState = Self.presentation(for: created)
        nextOrder += 1
        index[key] = snapshot.items.count
        snapshot.items.append(.segment(created))
        bump()
        return [.segmentCreated(created.id)]
    }

    // MARK: - Translation

    /// Explicit local review can address an older lane epoch; ordinary provider events
    /// still obey the epoch gates. Membership and source revision are checked atomically.
    @discardableResult
    public mutating func reviewVocabularyCandidate(segmentID: String, revision: Int,
                                                   candidate: VocabularyCorrectionCandidate, confirm: Bool) -> Bool {
        snapshot.reviewVocabularyCandidate(segmentID: segmentID, revision: revision, candidate: candidate, confirm: confirm)
    }

    private mutating func applyTranslation(_ event: CaptionEvent) -> [CaptionEffect] {
        guard let refs = event.sourceRefs, !refs.isEmpty, let text = event.text else {
            return [.dropped(eventID: event.eventID, reason: .malformed)]
        }
        let isFinal = event.type == .translationFinal || (event.isFinal ?? false)
        let translationID = event.translationID ?? event.eventID
        let keys = refs.map { Self.key(lane: event.laneID, providerEpoch: event.providerEpoch, segmentID: $0.segmentID) }
        guard let ownerIdx = index[keys[0]], case .segment(var owner) = snapshot.items[ownerIdx] else {
            return [.dropped(eventID: event.eventID, reason: .unknownSegment)]
        }
        if owner.presentationState == .frozen {
            return [.dropped(eventID: event.eventID, reason: .finalizedSegment)]
        }
        let basedOn = refs.first { $0.segmentID == owner.providerSegmentID }?.revision ?? refs[0].revision
        let anySourceStale = zip(refs, keys).contains { ref, key in
            guard let i = index[key], case .segment(let segment) = snapshot.items[i] else { return true }
            return ref.revision < segment.sourceRevision
        }

        // Invariant 2: never let an older-revision translation replace a newer one.
        if let existing = owner.translation {
            if let previous = existing.sourceRefs, refs.contains(where: { ref in
                previous.contains { $0.segmentID == ref.segmentID && ref.revision < $0.revision }
            }) { return [.dropped(eventID: event.eventID, reason: .staleTranslation)] }
            if basedOn < existing.basedOnRevision {
                return [.dropped(eventID: event.eventID, reason: .staleTranslation)]
            }
            if basedOn == existing.basedOnRevision, existing.isFinal, !isFinal {
                return [.dropped(eventID: event.eventID, reason: .staleTranslation)]
            }
            if owner.presentationState == .final, existing.isFinal, isFinal, existing.text == text {
                return [.dropped(eventID: event.eventID, reason: .duplicateEvent)]
            }
        }
        let quality: TimingQuality = event.timingQuality ?? (keys.count == 1 ? owner.timingQuality : .estimated)
        owner.translation = CaptionTranslation(
            id: translationID,
            text: text,
            language: event.language,
            basedOnRevision: basedOn,
            isFinal: isFinal,
            isStale: anySourceStale,
            coveredSegmentIDs: keys,
            timingQuality: quality,
            sourceRefs: refs
        )
        owner.presentationState = Self.presentation(for: owner)
        snapshot.items[ownerIdx] = .segment(owner)
        var effects: [CaptionEffect] = [.translationChanged(owner.id)]
        for k in keys.dropFirst() {
            if let i = index[k], case .segment(var s) = snapshot.items[i], s.presentationState != .frozen {
                s.mergedIntoTranslation = translationID
                s.presentationState = Self.presentation(for: s)
                snapshot.items[i] = .segment(s)
                effects.append(.segmentChanged(s.id))
            }
        }
        bump()
        return effects
    }

    // MARK: - Gap / freeze

    private mutating func applyGap(_ event: CaptionEvent) -> [CaptionEffect] {
        guard let start = event.startNs, let end = event.endNs else {
            return [.dropped(eventID: event.eventID, reason: .malformed)]
        }
        let gap = CaptionGap(
            id: "gap/\(event.laneID)/\(event.eventID)",
            laneID: event.laneID,
            captureEpoch: event.captureEpoch,
            startNs: start,
            endNs: end,
            reason: event.gapReason ?? "unknown",
            order: nextOrder
        )
        nextOrder += 1
        snapshot.items.append(.gap(gap))
        bump()
        return [.gapRecorded(gap.id)]
    }

    private mutating func freezeLane(_ lane: String, upTo epoch: UInt64) -> [CaptionEffect] {
        var effects: [CaptionEffect] = []
        for (i, item) in snapshot.items.enumerated() {
            if case .segment(var s) = item, s.laneID == lane, s.providerEpoch < epoch, s.presentationState != .frozen {
                if s.presentationState != .final {
                    Self.freeze(&s, reason: "引擎重连，这句没有定稿")
                    snapshot.items[i] = .segment(s)
                    effects.append(.segmentChanged(s.id))
                }
            }
        }
        snapshot.activeProviderEpochs[lane] = epoch
        var set = seen[lane] ?? SeenSet(epoch: epoch)
        set.previous = (set.epoch, set.ids)
        set.epoch = epoch
        set.ids = []
        set.ring = []
        seen[lane] = set
        effects.append(.laneFrozen(lane: lane, providerEpoch: epoch))
        bump()
        return effects
    }

    /// Session ended (user stop, engine gone, error): every segment that is not final is frozen
    /// as-is and marked incomplete, so nothing stays in "识别中 / 翻译中" forever and nothing is
    /// silently counted as a finished sentence. Idempotent.
    public mutating func freezeOpenSegments(reason: String) -> [CaptionEffect] {
        var effects: [CaptionEffect] = []
        for (i, item) in snapshot.items.enumerated() {
            guard case .segment(var s) = item else { continue }
            guard s.presentationState != .final, s.presentationState != .frozen else { continue }
            Self.freeze(&s, reason: reason)
            snapshot.items[i] = .segment(s)
            effects.append(.segmentChanged(s.id))
        }
        if !effects.isEmpty { bump() }
        return effects
    }

    private static func freeze(_ s: inout CaptionSegment, reason: String) {
        if s.corrected, s.originalRecognitionText != nil {
            // A user-reviewed final is complete recognition. Its old translation is
            // deliberately stale, not evidence that the recognizer failed to finalize.
            s.presentationState = .frozen
            return
        }
        // A segment whose source was final and only lacked a translation is still "incomplete"
        // for the user: the translation will never come.
        s.presentationState = .frozen
        s.sourceFinal = true
        s.incompleteReason = reason
        if var t = s.translation { t.isFinal = true; s.translation = t }
    }

    // MARK: - Helpers

    private static func presentation(for s: CaptionSegment) -> PresentationState {
        if s.presentationState == .frozen { return .frozen }
        if s.sourceText.isEmpty { return .listening }
        if s.mergedIntoTranslation != nil {
            return s.sourceFinal ? .stable : .preview
        }
        if s.sourceFinal {
            if s.corrected, s.translation?.isStale == true { return .stable }
            if let t = s.translation, !t.isStale {
                return t.isFinal ? .final : .stable
            }
            return .awaitingTranslation
        }
        return .preview
    }

    private func isDuplicate(_ e: CaptionEvent) -> Bool {
        guard let set = seen[e.laneID] else { return false }
        if set.epoch == e.providerEpoch { return set.ids.contains(e.eventID) }
        if let p = set.previous, p.epoch == e.providerEpoch { return p.ids.contains(e.eventID) }
        return false
    }

    private mutating func remember(_ e: CaptionEvent) {
        var set = seen[e.laneID] ?? SeenSet(epoch: e.providerEpoch)
        if set.epoch != e.providerEpoch { return }
        set.ids.insert(e.eventID)
        set.ring.append(e.eventID)
        if set.ring.count > seenLimitPerEpoch {
            let evict = set.ring.removeFirst()
            set.ids.remove(evict)
        }
        seen[e.laneID] = set
    }

    private mutating func bump() {
        snapshot.version &+= 1
    }

    /// Drops finalized items older than `keepLast` from working memory (history lives in persistence).
    public mutating func compact(keepLast: Int) {
        guard snapshot.items.count > keepLast else { return }
        let removeCount = snapshot.items.count - keepLast
        var removed = 0
        var newItems: [CaptionItem] = []
        for item in snapshot.items {
            if removed < removeCount, case .segment(let s) = item, s.presentationState == .final || s.presentationState == .frozen {
                removed += 1
                continue
            }
            if removed < removeCount, case .gap = item {
                removed += 1
                continue
            }
            newItems.append(item)
        }
        snapshot.items = newItems
        index = [:]
        for (i, item) in snapshot.items.enumerated() {
            if case .segment(let s) = item { index[s.id] = i }
        }
        bump()
    }
}
