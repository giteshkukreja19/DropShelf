import XCTest
import UniformTypeIdentifiers
@testable import ShelfDemo

final class OCRMenuTests: XCTestCase {
    @MainActor
    func test_makeSearchable_offered_for_pdfs_only() async {
        XCTAssertTrue(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [UTType.pdf]))
        XCTAssertTrue(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.pdf, .pdf]))
    }

    @MainActor
    func test_makeSearchable_not_offered_for_images() async {
        XCTAssertFalse(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.png]))
        XCTAssertFalse(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.heic]))
    }

    @MainActor
    func test_makeSearchable_not_offered_for_mixed() async {
        XCTAssertFalse(
            OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.pdf, .png])
        )
    }

    @MainActor
    func test_makeSearchable_not_offered_for_empty() async {
        XCTAssertFalse(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: []))
    }

    @MainActor
    func test_extractText_offered_for_pdfs() async {
        XCTAssertTrue(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.pdf]))
    }

    @MainActor
    func test_extractText_offered_for_images() async {
        XCTAssertTrue(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.png]))
        XCTAssertTrue(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.heic, .jpeg]))
    }

    @MainActor
    func test_extractText_offered_for_mixed_pdf_image() async {
        // Both PDFs and images are valid for Extract Text, so any mix works.
        XCTAssertTrue(
            OCRMenu.shouldOfferExtractText(forSourceUTIs: [.pdf, .png, .heic])
        )
    }

    @MainActor
    func test_extractText_not_offered_for_unsupported_uti() async {
        XCTAssertFalse(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.plainText]))
    }

    @MainActor
    func test_extractText_not_offered_for_mixed_with_unsupported() async {
        XCTAssertFalse(
            OCRMenu.shouldOfferExtractText(forSourceUTIs: [.pdf, .plainText])
        )
    }

    @MainActor
    func test_extractText_not_offered_for_empty() async {
        XCTAssertFalse(OCRMenu.shouldOfferExtractText(forSourceUTIs: []))
    }
}
