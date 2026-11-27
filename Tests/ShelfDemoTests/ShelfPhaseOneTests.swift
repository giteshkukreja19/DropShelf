import XCTest
@testable import ShelfDemo

final class ShelfPhaseOneTests: XCTestCase {
    @MainActor func testExistingFolderRuleDecodesWithoutOrganization() async throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/example","enabled":true,"filter":"All files","newShelf":false,"recursive":false,"delayProcessing":false,"nameContains":""}
        """.utf8)
        let rule = try JSONDecoder().decode(ShelfFolderRule.self, from: data)
        XCTAssertNil(rule.organization)
        XCTAssertTrue(rule.enabled)
    }
    @MainActor func testOrganizationCategories() async {
        XCTAssertEqual(ShelfOrganization.category(URL(fileURLWithPath: "/tmp/file.pdf")), "Documents")
        XCTAssertEqual(ShelfOrganization.category(URL(fileURLWithPath: "/tmp/file.png")), "Images")
        XCTAssertEqual(ShelfOrganization.category(URL(fileURLWithPath: "/tmp/file.dmg")), "Installers")
        XCTAssertEqual(ShelfOrganization.category(URL(fileURLWithPath: "/tmp/file.zip")), "Archives")
    }
    @MainActor func testFileActionsRespectSelection() async {
        XCTAssertTrue(ShelfPhaseOneActions.options([URL(fileURLWithPath: "/tmp/deck.pptx")]).contains("Convert Document to PDF…"))
        XCTAssertFalse(ShelfPhaseOneActions.options([URL(fileURLWithPath: "/tmp/deck.pptx"), URL(fileURLWithPath: "/tmp/image.png")]).contains("Remove Background…"))
        XCTAssertTrue(ShelfPhaseOneActions.options([]).isEmpty)
    }
    @MainActor func testOrganizationCopyDoesNotOverwrite() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("in"), out = root.appendingPathComponent("out")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true); try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let src = incoming.appendingPathComponent("test.txt"), existing = out.appendingPathComponent("test.txt")
        try Data("new".utf8).write(to: src); try Data("old".utf8).write(to: existing)
        var rule = ShelfOrganizationRule(); rule.action = "Copy"; rule.destination = out.path
        let result = ShelfOrganization.organize([src], rule: rule, monitors: [])
        XCTAssertEqual(result.urls.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: src), Data("new".utf8))
        XCTAssertNotEqual(result.urls.first, existing)
    }
}
