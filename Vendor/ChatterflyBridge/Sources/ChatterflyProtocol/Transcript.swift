import Foundation

public struct ChatterflyTranscript {
    private var segments: [(start: Double, end: Double, text: String, final: Bool)] = []
    public private(set) var sawFinal = false
    public var isFullyFinal: Bool { !segments.isEmpty && segments.allSatisfy { $0.final } }
    public var text: String { segments.map(\.text).joined() }
    public init() { }

    public mutating func receive(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatterflyFailure.invalidResponse }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? Int, code != 0 { throw ChatterflyFailure.server(code) }
        if (json["events"] as? [[String: Any]])?.contains(where: { $0["event_type"] as? String == "END_OF_SINGLE_UTTERANCE" || $0["event_type"] as? Int == 1 }) == true {
            throw ChatterflyFailure.server(-2100)
        }
        for result in json["results"] as? [[String: Any]] ?? [] {
            guard let alternatives = result["alternatives"] as? [[String: Any]], let transcript = alternatives.first?["transcript"] as? String else { continue }
            let start = number(result["start_time"]), end = number(result["end_time"])
            let final = result["is_final"] as? Bool ?? false
            segments.removeAll { $0.start == start || ($0.start < end && $0.end > start) }
            segments.append((start, end, transcript, final))
            segments.sort { $0.start < $1.start }
            sawFinal = segments.contains { $0.final }
        }
        return text
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }
}
