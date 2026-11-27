import XCTest
@testable import ShelfDemo

final class ShelfScreenPositionTests: XCTestCase {
    func testNinePositionsAndOffsetDisplay() {
        let screen = CGRect(x: -1200, y: 50, width: 1200, height: 800)
        let size = CGSize(width: 200, height: 100)
        let expected: [CGPoint] = [CGPoint(x: -1188, y: 738), CGPoint(x: -700, y: 738), CGPoint(x: -212, y: 738), CGPoint(x: -1188, y: 400), CGPoint(x: -700, y: 400), CGPoint(x: -212, y: 400), CGPoint(x: -1188, y: 62), CGPoint(x: -700, y: 62), CGPoint(x: -212, y: 62)]
        for (position, point) in zip(ShelfScreenPosition.allCases, expected) {
            XCTAssertEqual(position.origin(for: size, in: screen), point)
        }
    }
    func testAvoidsExistingShelf() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 200)
        let first = CGRect(origin: ShelfScreenPosition.topRight.origin(for: size, in: screen), size: size)
        let second = CGRect(origin: ShelfScreenPosition.topRight.origin(for: size, in: screen, avoiding: [first]), size: size)
        XCTAssertFalse(first.intersects(second))
        XCTAssertTrue(screen.contains(second))
    }
    func testSmoothstepEndpointsAndMonotonicity() {
        XCTAssertEqual(ShelfScreenPosition.progress(-1), 0)
        XCTAssertEqual(ShelfScreenPosition.progress(1), 1)
        XCTAssertEqual(ShelfScreenPosition.progress(0.5), 0.5)
        let values = (0...100).map { ShelfScreenPosition.progress(Double($0) / 100) }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }
    func testFixedManualSizeAndPreset() {
        let visible = CGSize(width: 1400, height: 900)
        let manual = CGSize(width: 430, height: 310)
        let stored = ShelfExpandedGeometry.encode(manual)
        XCTAssertEqual(ShelfExpandedGeometry.decode(stored), manual)
        XCTAssertEqual(ShelfExpandedGeometry.preferred(percent: 100, fixed: true, custom: stored, visible: visible), manual)
        XCTAssertEqual(ShelfExpandedGeometry.preferred(percent: 100, fixed: false, custom: stored, visible: visible), CGSize(width: 520, height: 560))
        XCTAssertEqual(ShelfExpandedGeometry.preferred(percent: 100, fixed: true, custom: "", visible: visible), CGSize(width: 420, height: 284))
        XCTAssertNil(ShelfExpandedGeometry.decode("nan,400"))
        XCTAssertNil(ShelfExpandedGeometry.decode("10,10"))
    }
    func testSmallerDisplayClampsWithoutChangingStoredSize() {
        let stored = "700,600"
        XCTAssertEqual(ShelfExpandedGeometry.preferred(percent: 100, fixed: true, custom: stored, visible: CGSize(width: 500, height: 400)), CGSize(width: 484, height: 384))
        XCTAssertEqual(ShelfExpandedGeometry.decode(stored), CGSize(width: 700, height: 600))
    }

    func testCompactExpandedLayout() {
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveWidth(maximum: 520, count: 1, isList: false), 420)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveWidth(maximum: 520, count: 2, isList: false), 420)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveWidth(maximum: 520, count: 3, isList: false), 520)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveWidth(maximum: 520, count: 1, isList: true), 520)
        XCTAssertEqual(ShelfExpandedGeometry.columns(contentWidth: 500, count: 1), 1)
        XCTAssertEqual(ShelfExpandedGeometry.columns(contentWidth: 500, count: 2), 2)
        XCTAssertEqual(ShelfExpandedGeometry.columns(contentWidth: 500, count: 10), 4)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveHeight(width: 520, count: 1, isList: false, maximum: 560), 284)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveHeight(width: 520, count: 4, isList: false, maximum: 560), 284)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveHeight(width: 520, count: 5, isList: false, maximum: 560), 456)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveHeight(width: 520, count: 50, isList: false, maximum: 560), 560)
        XCTAssertEqual(ShelfExpandedGeometry.adaptiveHeight(width: 520, count: 1, isList: true, maximum: 560), 280)
    }
}
