import Testing
@testable import CaptionDomain

@Suite("Read-aloud gate")
struct ReadAloudGateTests {
    @Test("Each sentence once; punctuation-only revisions are not read twice")
    func dedup() {
        var g = ReadAloudGate()
        #expect(g.speakable("请不要重启服务器。") == "请不要重启服务器。")
        #expect(g.speakable("请不要重启服务器") == nil)
        #expect(g.speakable("  ") == nil)
        #expect(g.speakable("Please do not restart the server yet.") == "Please do not restart the server yet.")
        #expect(g.speakable("please do not restart the server yet") == nil)
    }

    @Test("A final that extends the sentence already read contributes only its tail")
    func extendsSentence() {
        var g = ReadAloudGate()
        #expect(g.speakable("The retry storm you are seeing") == "The retry storm you are seeing")
        #expect(g.speakable("The retry storm you are seeing is a symptom, not the cause.") == "is a symptom, not the cause.")
        #expect(g.speakable("The retry storm you are seeing is a symptom, not the cause!") == nil)
        var h = ReadAloudGate()
        #expect(h.speakable("你看到的重试风暴") == "你看到的重试风暴")
        #expect(h.speakable("你看到的重试风暴是症状，不是原因。") == "是症状，不是原因。")
    }

    @Test("Memory is bounded and reset forgets everything")
    func memory() {
        var g = ReadAloudGate()
        g.memory = 3
        for i in 0..<5 { #expect(g.speakable("sentence \(i)") != nil) }
        #expect(g.speakable("sentence 0") != nil, "fell out of the memory window")
        #expect(g.speakable("sentence 4") == nil)
        g.reset()
        #expect(g.speakable("sentence 4") != nil)
    }
}
