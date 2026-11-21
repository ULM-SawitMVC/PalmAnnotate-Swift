import XCTest

final class ManualTreeIDTests: XCTestCase {
    @MainActor func testManualTreeIDInPortrait() { checkManualTreeID(.portrait) }
    @MainActor func testManualTreeIDInLandscape() { checkManualTreeID(.landscapeLeft) }

    @MainActor
    private func checkManualTreeID(_ orientation: UIDeviceOrientation) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-manual-id"]
        app.launch()

        let module = app.staticTexts["Multisisi"]
        XCTAssertTrue(module.waitForExistence(timeout: 30))
        module.tap()
        app.staticTexts["DAMIMAS · QM"].tap()
        app.buttons.containing(.staticText, identifier: "Tangkap sampel").firstMatch.tap()

        let field = app.textFields["manual-tree-id"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "4")
        attachScreenshot(named: "Tangkapan dengan ID manual")

        replace(field, with: "3", in: app)
        save(app)
        let refusal = app.alerts["PalmAnnotate"]
        XCTAssertTrue(refusal.waitForExistence(timeout: 10))
        XCTAssertTrue(refusal.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "DAMIMAS_QM_0003 sudah ada")).firstMatch.exists)
        refusal.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["4 / 4 foto"].exists, "A refused ID must keep the draft")

        replace(field, with: "7", in: app)
        save(app)
        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["DAMIMAS_QM_0007"].exists)
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        let ready = expectation(for: NSPredicate(format: "isEnabled == true AND isHittable == true"), evaluatedWith: field)
        wait(for: [ready], timeout: 15)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        XCTAssertEqual(field.value as? String, text)
        app.buttons["Selesai"].tap()
    }

    @MainActor
    private func save(_ app: XCUIApplication) {
        let save = app.buttons["Simpan sampel"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        let saveAnyway = app.buttons["Simpan tetap"]
        XCTAssertTrue(saveAnyway.waitForExistence(timeout: 5))
        saveAnyway.tap()
    }
}
