import XCTest
import Foundation
@testable import ShelfDemo

final class ShelfOCRTranslationTests: XCTestCase {
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
