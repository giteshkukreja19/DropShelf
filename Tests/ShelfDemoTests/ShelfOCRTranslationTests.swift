import XCTest
import Foundation
@testable import ShelfDemo

final class ShelfOCRTranslationTests: XCTestCase {
    func testWrappedQuotes() {
        XCTAssertEqual(OCRTextPreparation.prepare("When You\nFocus On The\nGood, The Good\n•Gets Better"), "When You Focus On The Good, The Good Gets Better")
        XCTAssertEqual(OCRTextPreparation.prepare("Focus on\nthe good\nand the\ngood gets\nbetter."), "Focus on the good and the good gets better.")
        XCTAssertEqual(OCRTextPreparation.prepare("Speak when\nyour words\nare more\nbeautiful\nthan\nsilence."), "Speak when your words are more beautiful than silence.")
        XCTAssertEqual(OCRTextPreparation.prepare("तभी बोलें\nजब आपके शब्द\nमौन से अधिक\nसुंदर हों।"), "तभी बोलें जब आपके शब्द मौन से अधिक सुंदर हों।")
        XCTAssertEqual(OCRTextPreparation.prepare("First paragraph.\n\n• Item one\n• Item two"), "First paragraph.\n\n• Item one\n• Item two")
    }
    func testSameLanguage() {
        XCTAssertTrue(OCRTextPreparation.languageMatches("en-US", "en-GB"))
        XCTAssertTrue(OCRTextPreparation.languageMatches("hi", "hi-IN"))
        XCTAssertFalse(OCRTextPreparation.languageMatches("hi", "en"))
    }
    func testMetadataRoundTripAndPlainText() throws {
        let info = ShelfOCRMetadata(original: "Hallo", source: "de", target: "en")
        let decoded = try JSONDecoder().decode(ShelfOCRMetadata.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(info, decoded)
        let item = ShelfItem(type: .text, textContent: "Hello", translation: decoded)
        XCTAssertEqual(item.textContent, "Hello")
        XCTAssertEqual(item.translation?.original, "Hallo")
        XCTAssertNil(ShelfItem(type: .text, textContent: "Ordinary text").translation)
    }
}
