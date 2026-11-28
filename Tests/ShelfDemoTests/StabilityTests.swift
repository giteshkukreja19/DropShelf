import XCTest
@testable import ShelfDemo

final class StabilityTests: XCTestCase {
    func testRetentionRefreshPreservesIdentityAndMetadata() {
        let original = ShelfItem(type: .text, textContent: "Hello", createdAt: Date(timeIntervalSince1970: 10), translation: ShelfOCRMetadata(original: "Hallo", source: "de", target: "en"))
        let date = Date(timeIntervalSince1970: 20)
        let refreshed = original.refreshingRetention(at: date)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.textContent, original.textContent)
        XCTAssertEqual(refreshed.translation, original.translation)
        XCTAssertEqual(refreshed.createdAt, date)
    }
    func testTranslationChunkBoundAndLosslessInput() {
        let text = String(repeating: "Hello world. नमस्ते। 日本語。 ", count: 400)
        let chunks = OCRTextPreparation.translationChunks(text, limit: 100)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 100 })
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(OCRTextPreparation.translationChunks(""), [])
        XCTAssertEqual(OCRTextPreparation.translationChunks("abc", limit: 0), ["a", "b", "c"])
    }
    func testFitPreservesAspectAndBounds() {
        XCTAssertEqual(ShelfPixelSize(width: 1920, height: 1080).fitted(maxWidth: 500, maxHeight: 500), ShelfPixelSize(width: 500, height: 281))
        XCTAssertEqual(ShelfPixelSize(width: 1080, height: 1920).fitted(maxWidth: 500, maxHeight: 500), ShelfPixelSize(width: 281, height: 500))
        XCTAssertEqual(ShelfPixelSize(width: 300, height: 200).fitted(maxWidth: 500, maxHeight: 500), ShelfPixelSize(width: 300, height: 200))
        XCTAssertEqual(ShelfPixelSize(width: 300, height: 200).fitted(maxWidth: 600, maxHeight: 400, allowEnlargement: true), ShelfPixelSize(width: 600, height: 400))
        XCTAssertNil(ShelfPixelSize(width: 0, height: 200).fitted(maxWidth: 500, maxHeight: 500))
        XCTAssertFalse(ShelfPixelSize(width: 16000, height: 16000).isSafeToRender)
    }
    func testCommitNeverOverwrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output.txt")
        try ShelfWritableStorage.commit(Data("first".utf8), to: output)
        XCTAssertThrowsError(try ShelfWritableStorage.commit(Data("second".utf8), to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["output.txt"])
    }
}
