// Typeless document: 80/20 cursor window, non-cascade replace, bounded learn (spec §19).
// All offsets are Unicode code points, matching Python `str` indexing.

public enum TypelessError: Error, Equatable, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let m): return m } }
}

public let defaultWindowChars = 2048
public let defaultFrequency: Int64 = 8
public let learnMaxLen = 64
public let feedbackChars = 256

public struct Replacement: Hashable, Sendable {
    public var source: String
    public var target: String
    public var frequency: Int64
    public init(_ source: String, _ target: String, _ frequency: Int64 = defaultFrequency) {
        self.source = source
        self.target = target
        self.frequency = frequency
    }
}

public struct Hotword: Hashable, Sendable {
    public var word: String
    public var frequency: Int64
    public init(_ word: String, _ frequency: Int64 = defaultFrequency) {
        self.word = word
        self.frequency = frequency
    }
}

public struct CursorWindow: Equatable, Sendable {
    public var text: String
    public var cursor: Int
    public var start: Int
    public var end: Int
}

typealias Scalars = [Unicode.Scalar]

@inline(__always) func scalars(_ s: String) -> Scalars { Array(s.unicodeScalars) }
@inline(__always) func string(_ s: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(s)) }
@inline(__always) func string(_ s: Scalars) -> String { String(String.UnicodeScalarView(s)) }

public func clampCursor(_ text: String, _ cursor: Int) -> Int {
    clampCursor(count: text.unicodeScalars.count, cursor)
}

@inline(__always) func clampCursor(count: Int, _ cursor: Int) -> Int {
    if cursor < 0 { return 0 }
    if cursor > count { return count }
    return cursor
}

public func cursorWindow(_ text: String, _ cursor: Int, limit: Int = defaultWindowChars) -> CursorWindow {
    let s = scalars(text)
    let n = s.count
    let c = clampCursor(count: n, cursor)
    if limit <= 0 || n <= limit {
        return CursorWindow(text: text, cursor: c, start: 0, end: n)
    }
    let beforeBudget = Int(Double(limit) * 0.8)
    let afterBudget = limit - beforeBudget
    var before = min(c, beforeBudget)
    var after = min(n - c, afterBudget)
    var unused = limit - before - after
    let availAfter = (n - c) - after
    let extraAfter = min(unused, availAfter)
    after += extraAfter
    unused -= extraAfter
    let availBefore = c - before
    let extraBefore = min(unused, availBefore)
    before += extraBefore
    let start = c - before
    let end = c + after
    return CursorWindow(text: string(s[start..<end]), cursor: before, start: start, end: end)
}

public func parseHotwords(_ value: JSONValue?) throws -> [Hotword] {
    guard let value = value, value.pythonTruthy else { return [] }
    var out: [Hotword] = []
    if let obj = value.objectValue {
        for (word, freq) in obj.pairs where !word.isEmpty {
            out.append(Hotword(word, freq.intValue ?? defaultFrequency))
        }
        return out
    }
    guard let items = value.arrayValue else { throw TypelessError.message("hotwords must be an array or object") }
    for item in items {
        if let s = item.stringValue {
            if !s.isEmpty { out.append(Hotword(s, defaultFrequency)) }
        } else if let obj = item.objectValue {
            let wordValue = obj["word"]?.pythonTruthy == true ? obj["word"] : obj["text"]
            guard let word = wordValue?.stringValue, !word.isEmpty else { continue }
            out.append(Hotword(word, obj["frequency"]?.intValue ?? defaultFrequency))
        }
    }
    return out
}

private func pyStr(_ v: JSONValue) -> String {
    switch v {
    case .string(let s): return s
    case .null: return "None"
    case .bool(let b): return b ? "True" : "False"
    default: return v.compactJSON()
    }
}

public func parseReplacements(_ value: JSONValue?) throws -> [Replacement] {
    guard let value = value, value.pythonTruthy else { return [] }
    var out: [Replacement] = []
    if let obj = value.objectValue {
        for (source, target) in obj.pairs {
            if source.isEmpty { throw TypelessError.message("empty source illegal") }
            out.append(Replacement(source, target.isNull ? "" : pyStr(target), defaultFrequency))
        }
        return out
    }
    guard let items = value.arrayValue else { throw TypelessError.message("replacements must be an array or object") }
    for item in items {
        guard let obj = item.objectValue else { throw TypelessError.message("replacement entries must be objects") }
        guard let source = obj["source"]?.stringValue, !source.isEmpty else {
            throw TypelessError.message("empty source illegal")
        }
        let target: String
        switch obj["target"] {
        case nil, .null?: target = ""
        case .string(let s)?: target = s
        case let other?: target = pyStr(other)
        }
        out.append(Replacement(source, target, obj["frequency"]?.intValue ?? defaultFrequency))
    }
    return out
}

public func mergeHotwords(_ groups: [Hotword]...) -> [Hotword] {
    var best: [String: Int] = [:]
    var out: [Hotword] = []
    for group in groups {
        for item in group where !item.word.isEmpty {
            if let idx = best[item.word] {
                if item.frequency > out[idx].frequency { out[idx] = item }
            } else {
                best[item.word] = out.count
                out.append(item)
            }
        }
    }
    return out
}

/// Literal, longest-source-first, single-pass non-cascading replacement.
public func applyReplacements(_ text: String, _ rules: [Replacement]) throws -> String {
    if rules.isEmpty { return text }
    var bySource: [String: (rule: Replacement, order: Int)] = [:]
    var order = 0
    for rule in rules {
        if rule.source.isEmpty { throw TypelessError.message("empty source illegal") }
        if let existing = bySource[rule.source] {
            bySource[rule.source] = (rule, existing.order)
        } else {
            bySource[rule.source] = (rule, order)
            order += 1
        }
    }
    let sorted = bySource.values.sorted {
        let la = $0.rule.source.unicodeScalars.count, lb = $1.rule.source.unicodeScalars.count
        return la != lb ? la > lb : $0.order < $1.order
    }
    let compiled: [(src: Scalars, tgt: Scalars)] = sorted.map { (scalars($0.rule.source), scalars($0.rule.target)) }
    let input = scalars(text)
    var out: Scalars = []
    out.reserveCapacity(input.count)
    var i = 0
    let n = input.count
    outer: while i < n {
        for entry in compiled where i + entry.src.count <= n {
            var match = true
            for k in 0..<entry.src.count where input[i + k] != entry.src[k] { match = false; break }
            if match {
                out.append(contentsOf: entry.tgt)
                i += entry.src.count
                continue outer
            }
        }
        out.append(input[i])
        i += 1
    }
    return string(out)
}

private func lcp(_ a: Scalars, _ b: Scalars) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n && a[i] == b[i] { i += 1 }
    return i
}

private func lcsuffix(_ a: Scalars, _ b: Scalars) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n && a[a.count - 1 - i] == b[b.count - 1 - i] { i += 1 }
    return i
}

public struct LearnedEdit: Equatable, Sendable {
    public var source: String
    public var target: String
    public var before: String
    public var after: String
}

public func learnUserEdit(original: String, revised: String) -> LearnedEdit? {
    let o = scalars(original), r = scalars(revised)
    let prefix = lcp(o, r)
    var origMid = Array(o[prefix...])
    var revMid = Array(r[prefix...])
    let suffix = lcsuffix(origMid, revMid)
    if suffix > 0 {
        origMid.removeLast(suffix)
        revMid.removeLast(suffix)
    }
    if origMid.isEmpty { return nil }
    if max(origMid.count, revMid.count) > learnMaxLen { return nil }
    let before = string(o[max(0, prefix - feedbackChars)..<prefix])
    let afterStart = prefix + origMid.count
    let after = string(o[afterStart..<min(o.count, afterStart + feedbackChars)])
    return LearnedEdit(source: string(origMid), target: string(revMid), before: before, after: after)
}

public final class TypelessDocument {
    public private(set) var text: String
    public private(set) var cursorPosition: Int
    public var contextWindowChars: Int
    public private(set) var replacementLexicon: [Replacement]

    public init(_ text: String = "", cursorPosition: Int? = nil, contextWindowChars: Int = defaultWindowChars,
                replacements: [Replacement] = []) {
        self.text = text
        let n = text.unicodeScalars.count
        self.cursorPosition = clampCursor(count: n, cursorPosition ?? n)
        self.contextWindowChars = contextWindowChars
        self.replacementLexicon = replacements
    }

    public static func fromStart(_ start: JSONObject) throws -> TypelessDocument {
        var context = ""
        if let c = start["context"], c.pythonTruthy { context = c.stringValue ?? pyStr(c) }
        let n = context.unicodeScalars.count
        var cursor = n
        if let c = start["cursor_position"], !c.isNull {
            guard let i = c.intValue else { throw TypelessError.message("cursor_position must be an integer") }
            cursor = Int(i)
        }
        var window = defaultWindowChars
        if let w = start["context_window_chars"]?.intValue, w > 0 { window = Int(w) }
        let rules = try parseReplacements(start["replacements"])
        return TypelessDocument(context, cursorPosition: cursor, contextWindowChars: window, replacements: rules)
    }

    public func addReplacement(_ source: String, _ target: String, frequency: Int64 = defaultFrequency) throws {
        if source.isEmpty { throw TypelessError.message("empty source illegal") }
        replacementLexicon.append(Replacement(source, target, frequency))
    }

    public func replace(_ transcript: String) throws -> String { try applyReplacements(transcript, replacementLexicon) }

    public func window() -> CursorWindow { cursorWindow(text, cursorPosition, limit: contextWindowChars) }

    public func hotwordsFromReplacements() -> [Hotword] {
        replacementLexicon.compactMap { $0.target.isEmpty ? nil : Hotword($0.target, $0.frequency) }
    }

    public func preview(_ transcript: String) throws -> String {
        let corrected = try replace(transcript)
        let s = scalars(text)
        let cursor = clampCursor(count: s.count, cursorPosition)
        return string(s[0..<cursor]) + corrected + string(s[cursor...])
    }

    public func commit(_ transcript: String) throws -> String {
        let corrected = try replace(transcript)
        let s = scalars(text)
        let cursor = clampCursor(count: s.count, cursorPosition)
        text = string(s[0..<cursor]) + corrected + string(s[cursor...])
        cursorPosition = cursor + corrected.unicodeScalars.count
        return corrected
    }

    @discardableResult
    public func learnFromRevision(original: String, revised: String) throws -> LearnedEdit? {
        guard let learned = learnUserEdit(original: original, revised: revised) else { return nil }
        try addReplacement(learned.source, learned.target)
        return learned
    }

    public func replacementRulesJSON() -> JSONValue {
        .array(replacementLexicon.map {
            .obj([("source", .string($0.source)), ("target", .string($0.target)), ("frequency", .int($0.frequency))])
        })
    }
}
