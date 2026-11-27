import XCTest
@testable import ShelfDemo

final class UpdateControllerTests: XCTestCase {
    private let key = "SUEnableAutomaticChecks"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    @MainActor
    func test_default_is_enabled_when_no_value_set() async {
        XCTAssertTrue(UpdateController.automaticallyChecksForUpdates)
    }

    @MainActor
    func test_setter_writes_userdefaults() async {
        UpdateController.automaticallyChecksForUpdates = false
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Bool,
            false
        )
        UpdateController.automaticallyChecksForUpdates = true
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Bool,
            true
        )
    }

    @MainActor
    func test_getter_reflects_userdefaults() async {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(UpdateController.automaticallyChecksForUpdates)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UpdateController.automaticallyChecksForUpdates)
    }
}
