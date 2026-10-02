import XCTest
@testable import LiveLearnApp

final class TranslationReplyFramerTests: XCTestCase {
    func testOnlyFramesFromCurrentLaunchAreAccepted() throws {
        var framer = TranslationReplyFramer(token: "current")
        let text = "LIVELEARN_TRANSLATION:other:{\"ok\":true,\"event\":\"vocabulary\"}\n" +
            "normal log\nLIVELEARN_TRANSLATION:current:{\"ok\":true,\"id\":\"expected\"}\n"
        XCTAssertEqual(try framer.append(Data(text.utf8)).map(\.id), ["expected"])
    }

    func testFragmentedUTF8AndMultipleReplies() throws {
        var framer = TranslationReplyFramer(token: "one")
        let text = "LIVELEARN_TRANSLATION:one:{\"ok\":true,\"translation\":\"中文🌏\"}\n" +
            "LIVELEARN_TRANSLATION:one:{\"ok\":true,\"id\":\"two\"}\n"
        var replies: [TranslationReply] = []
        for byte in Data(text.utf8) { replies += try framer.append(Data([byte])) }
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0].translation, "中文🌏")
        XCTAssertEqual(replies[1].id, "two")
    }

    func testOversizedLineResetsBufferAndAllowsRecovery() throws {
        var framer = TranslationReplyFramer(token: "one")
        framer.maximumLineBytes = 100
        XCTAssertThrowsError(try framer.append(Data(repeating: 65, count: 101)))
        let next = Data("LIVELEARN_TRANSLATION:one:{\"ok\":true}\n".utf8)
        XCTAssertEqual(try framer.append(next).count, 1)
    }
}
