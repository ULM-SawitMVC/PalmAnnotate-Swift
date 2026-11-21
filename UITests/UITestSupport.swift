import XCTest

extension XCUIElement {
    @MainActor
    func reveal(scrolling container: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 where !exists || !isHittable { container.swipeUp() }
        for _ in 0..<6 where !exists || !isHittable { container.swipeDown() }
        XCTAssertTrue(exists && isHittable, "Cannot reach \(self)", file: file, line: line)
    }
}

extension XCTestCase {
    @MainActor
    func attachScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
