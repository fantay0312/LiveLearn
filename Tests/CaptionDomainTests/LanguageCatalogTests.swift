import Testing
@testable import CaptionDomain

@Suite("Language catalog")
struct LanguageCatalogTests {
    @Test("Codes are unique, common languages come first, and the four original ones are still there")
    func shape() {
        let codes = LanguageCatalog.codes
        #expect(Set(codes).count == codes.count)
        #expect(codes.count >= 30)
        let firstMore = LanguageCatalog.all.firstIndex { !$0.isCommon } ?? codes.count
        let commonFirst = LanguageCatalog.all.prefix(firstMore).allSatisfy { $0.isCommon }
        let moreAfter = LanguageCatalog.all.dropFirst(firstMore).allSatisfy { !$0.isCommon }
        #expect(commonFirst)
        #expect(moreAfter)
        for c in ["zh-Hans", "en", "ja", "ko"] { #expect(codes.contains(c)) }
        #expect(!codes.contains(LanguageCatalog.auto), "auto is a pseudo-code, never a catalog row")
    }

    @Test("Names in Chinese and English, aliases, and the auto pseudo-code")
    func names() {
        #expect(LanguageCatalog.name("zh-Hans") == "中文")
        #expect(LanguageCatalog.name("zh") == "中文")
        #expect(LanguageCatalog.name("en") == "英语")
        #expect(LanguageCatalog.name(nil) == "自动")
        #expect(LanguageCatalog.name(LanguageCatalog.auto) == "自动")
        #expect(LanguageCatalog.name("xx-YY") == "xx-YY", "unknown codes pass through instead of vanishing")
        #expect(LanguageCatalog.englishName("zh-Hans") == "Simplified Chinese")
        #expect(LanguageCatalog.englishName("de") == "German")
        #expect(LanguageCatalog.canonical("zh") == "zh-Hans")
        #expect(LanguageCatalog.canonical("pt") == "pt-BR")
        #expect(LanguageCatalog.speechLocaleIdentifier(for: "en") == "en_US")
        #expect(LanguageCatalog.speechLocaleIdentifier(for: "yue") == "yue_CN")
        #expect(LanguageCatalog.speechLocaleIdentifier(for: "tlh") == "tlh")
    }
}
