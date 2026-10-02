import Foundation
import Translation
import NaturalLanguage
import CaptionDomain
import ProviderAdapters
import EngineKit

/// Apple's `Translation` framework (macOS 15) as a pipeline stage: on-device language packs,
/// nothing leaves the machine.
///
/// `TranslationSession` is not Sendable; it is only ever touched through the nonisolated
/// helpers below, which the queue awaits one at a time. The view-free session initializer
/// needs macOS 26, the same floor as the recognizer.
@available(macOS 26, *)
public final class AppleTextTranslator: TextTranslator, @unchecked Sendable {
    public static let stageID = "apple.translation"
    public var supportsGlossary: Bool { true }
    public var reusesPreviewForFinal: Bool { true }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: Self.stageID, displayName: "Apple 本机翻译", modelID: "apple/Translation", isLocal: true, dataDestination: "本机处理，不联网", costUnit: "免费")
    }

    private final class SessionBox: @unchecked Sendable {
        let session: TranslationSession
        let source: String
        init(source: String, target: String) {
            self.source = source
            session = TranslationSession(installedSource: LocalLanguage.translationLanguage(for: source), target: LocalLanguage.translationLanguage(for: target))
        }
    }

    private struct Configuration: Equatable {
        let id = UUID()
        let source: String?
        let target: String
    }

    private let lock = NSLock()
    private var box: SessionBox?
    private var configuration: Configuration?
    private let glossary: VocabularyMatcher

    public init(glossary: [VocabularyTerm] = []) {
        self.glossary = VocabularyMatcher(glossary)
    }

    public func availability(source: String?, target: String) async -> StageAvailability {
        let state = await LocalEngineAvailability.translationState(source: source, target: target)
        guard let source = Self.explicitSource(source) else {
            switch state {
            case .installed: return .ready
            case .downloadable, .downloading:
                return .blocked("尚未安装译为\(LanguageCatalog.name(target))的语言包。请在 设置 › 本地模型 中下载需要的翻译方向；自动识别只使用已安装的语言包。")
            case .unsupported:
                return .blocked("Apple 本机翻译不支持译为\(LanguageCatalog.name(target))；请更换目标语言或翻译引擎。")
            case .needsNewerOS:
                return .blocked("本机翻译需要 macOS 26 或更新版本。")
            }
        }
        let status = LocalPairStatus(source: source, target: target, speech: .installed, translation: state)
        return status.blocker.map { .blocked($0) } ?? .ready
    }

    /// Automatic input defers session creation until there is text to identify locally.
    public func prepare(source: String?, target: String) async throws {
        let config = Configuration(source: Self.explicitSource(source), target: LanguageCatalog.canonical(target))
        let old = lock.withLock {
            let old = box
            box = nil
            configuration = config
            return old
        }
        old?.session.cancel()
        if let source = config.source, source != config.target {
            _ = try await session(source: source, configuration: config)
        }
    }

    public func translate(_ text: String, source: String?, target: String, isFinal: Bool) async throws -> String {
        try Task.checkCancellation()
        guard let config = lock.withLock({ configuration }) else { throw ProviderError(.retryable, "本机翻译尚未准备") }
        let simplify = config.target == "zh-Hans"
        let matches = glossary.matches(in: text)
        // A complete term needs no model call and must retain the user's exact spelling.
        if matches.count == 1, let match = matches.first, match.range == text.startIndex..<text.endIndex {
            return match.replacement
        }
        guard text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return text }
        let detected = try config.source ?? Self.detectedSource(in: text)
        if detected == config.target {
            return Self.normalise(glossary.replacing(in: text), simplifyChinese: simplify, preserving: matches.map(\.replacement))
        }
        let box: SessionBox
        do {
            box = try await session(source: detected, configuration: config)
        } catch let error as ProviderError where !isFinal && error.classification == .userFixable {
            // A short preview can be identified differently once the sentence is complete.
            // Only a final's missing pack should stop the lane.
            throw ProviderError(.retryable, error.message)
        }
        if matches.isEmpty { return try await Self.translate(box, text, simplifyChinese: simplify) }
        if #available(macOS 26.4, *) {
            let input = Self.protectedInput(text, matches: matches)
            let output = try await Self.translateProtected(box, input)
            return Self.normalise(output, simplifyChinese: simplify, preserving: matches.map(\.replacement))
        }
        // Earlier systems cannot protect a range inside a sentence. Translate only the
        // surrounding spans, without asking a model to rewrite the fixed translations.
        return try await Self.translateSpans(text, matches: matches) { span in
            try await Self.translate(box, span, simplifyChinese: simplify)
        }
    }

    public func cancel() {
        let b = lock.withLock {
            let old = box
            configuration = nil
            box = nil
            return old
        }
        b?.session.cancel()
    }

    private static func explicitSource(_ source: String?) -> String? {
        guard let source, source != LanguageCatalog.auto else { return nil }
        return LanguageCatalog.canonical(source)
    }

    static func detectedSource(in text: String) throws -> String {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else {
            throw ProviderError(.retryable, "暂时无法判断这句话的语言；请继续说话，或在 设置 › 语言 中指定源语言。")
        }
        return LanguageCatalog.canonical(language.rawValue)
    }

    private func session(source: String, configuration config: Configuration) async throws -> SessionBox {
        try Task.checkCancellation()
        if let existing = lock.withLock({ configuration == config ? box : nil }), existing.source == source {
            return existing
        }
        let state = await LocalEngineAvailability.translationState(source: source, target: config.target)
        try Task.checkCancellation()
        guard lock.withLock({ configuration == config }) else { throw CancellationError() }
        let status = LocalPairStatus(source: source, target: config.target, speech: .installed, translation: state)
        if let blocker = status.blocker { throw ProviderError(.userFixable, blocker) }
        let fresh = SessionBox(source: source, target: config.target)
        let old = try lock.withLock {
            guard configuration == config else { throw CancellationError() }
            let old = box
            box = fresh
            return old
        }
        old?.session.cancel()
        do {
            try await Self.prepare(fresh)
            try Task.checkCancellation()
            guard lock.withLock({ configuration == config }) else { throw CancellationError() }
            return fresh
        } catch {
            let active = lock.withLock {
                if box === fresh { box = nil }
                return configuration == config
            }
            if error is CancellationError || Task.isCancelled || !active { throw CancellationError() }
            throw ProviderError(.userFixable, "\(LanguageCatalog.name(source)) → \(LanguageCatalog.name(config.target)) 的本机翻译不可用：\(error.localizedDescription)。请在 设置 › 本地模型 中确认语言包已下载")
        }
    }

    /// The system model occasionally answers a zh-Hans request in Traditional characters
    /// (seen once in 16 sentences on macOS 27 beta); normalise so the caption honours the setting.
    nonisolated static func normalise(_ text: String, simplifyChinese: Bool) -> String {
        guard simplifyChinese else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    nonisolated static func normalise(_ text: String, simplifyChinese: Bool, preserving terms: [String]) -> String {
        guard simplifyChinese else { return text }
        var cursor = text.startIndex, result = ""
        let terms = terms.filter { !$0.isEmpty }
        while cursor < text.endIndex {
            let next = terms.compactMap { text.range(of: $0, options: .literal, range: cursor..<text.endIndex) }
                .min { a, b in a.lowerBound == b.lowerBound ? a.upperBound > b.upperBound : a.lowerBound < b.lowerBound }
            guard let next else { break }
            result += normalise(String(text[cursor..<next.lowerBound]), simplifyChinese: true)
            result += text[next]
            cursor = next.upperBound
        }
        return result + normalise(String(text[cursor...]), simplifyChinese: true)
    }

    @available(macOS 26.4, *)
    nonisolated static func protectedInput(_ text: String, matches: [VocabularyMatcher.Match]) -> AttributedString {
        var result = AttributedString(), cursor = text.startIndex
        for match in matches {
            result += AttributedString(String(text[cursor..<match.range.lowerBound]))
            var fixed = AttributedString(match.replacement)
            fixed.translation.skipsTranslation = true
            result += fixed
            cursor = match.range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }

    nonisolated static func translateSpans(_ text: String, matches: [VocabularyMatcher.Match], translate: @Sendable (String) async throws -> String) async throws -> String {
        var result = "", cursor = text.startIndex
        func translated(_ span: Substring) async throws -> String {
            try Task.checkCancellation()
            let raw = String(span)
            let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard core.unicodeScalars.contains(where: CharacterSet.letters.contains), let range = raw.range(of: core) else { return raw }
            return String(raw[..<range.lowerBound]) + (try await translate(core)) + String(raw[range.upperBound...])
        }
        for match in matches {
            result += try await translated(text[cursor..<match.range.lowerBound])
            result += match.replacement
            cursor = match.range.upperBound
        }
        return result + (try await translated(text[cursor...]))
    }

    @available(macOS 26.4, *)
    nonisolated private static func translateProtected(_ box: SessionBox, _ text: AttributedString) async throws -> String {
        try await box.session.translate(text).targetText
    }

    nonisolated private static func prepare(_ box: SessionBox) async throws {
        try await box.session.prepareTranslation()
    }

    nonisolated private static func translate(_ box: SessionBox, _ text: String, simplifyChinese: Bool) async throws -> String {
        normalise(try await box.session.translate(text).targetText, simplifyChinese: simplifyChinese)
    }
}
