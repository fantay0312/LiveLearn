import XCTest
@testable import LiveLearnApp

final class TranslationDeepLinkTests: XCTestCase {
    func testTextIsDecodedOnceAndPreservesLiteralPunctuation() throws {
        let url = try XCTUnwrap(URL(string: "livelearn://query?text=A%26B%20%2B%20%E4%B8%AD%E6%96%87%0A%252F"))
        XCTAssertEqual(TranslationDeepLink.text(from: url), "A&B + 中文\n%2F")
    }

    func testPublicURLCannotSelectHelperControlActions() throws {
        for text in ["livelearn://shutdown?text=hello", "livelearn://image?text=/tmp/private.png",
                     "https://query?text=hello", "livelearn://query?text=", "livelearn://query?text=%20%0A",
                     "livelearn://query?text=one&text=two"] {
            XCTAssertNil(TranslationDeepLink.text(from: try XCTUnwrap(URL(string: text))))
        }
    }

    func testTranslationContentRemainsDataEvenWhenItLooksLikeACommand() throws {
        let url = try XCTUnwrap(URL(string: "livelearn://translate?text=easydict%3A%2F%2FresetUserDefaultsData"))
        XCTAssertEqual(TranslationDeepLink.text(from: url), "easydict://resetUserDefaultsData")
    }

    func testOversizedPublicInputIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "livelearn://query?text=" + String(repeating: "x", count: 262_145)))
        XCTAssertNil(TranslationDeepLink.text(from: url))
    }
}
