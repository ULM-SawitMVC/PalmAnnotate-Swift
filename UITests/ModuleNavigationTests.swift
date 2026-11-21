import XCTest

final class ModuleNavigationTests: XCTestCase {
    @MainActor
    func testModuleScreensInPortrait() {
        checkModuleScreens(orientation: .portrait)
    }

    @MainActor
    func testModuleScreensInLandscape() {
        checkModuleScreens(orientation: .landscapeLeft)
    }

    @MainActor
    func testWeightEditorAndExportsInPortrait() {
        checkWeightEditor(orientation: .portrait)
    }

    @MainActor
    func testWeightEditorAndExportsInLandscape() {
        checkWeightEditor(orientation: .landscapeLeft)
    }

    @MainActor
    private func checkWeightEditor(orientation: UIDeviceOrientation) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-capture"]
        app.launch()

        let module = app.staticTexts["Berat Tandan"]
        XCTAssertTrue(module.waitForExistence(timeout: 30))
        module.tap()
        app.staticTexts["DAMIMAS · QA"].tap()
        app.buttons.containing(.staticText, identifier: "Tangkap sampel").firstMatch.tap()
        XCTAssertTrue(app.buttons["Pilih foto simulator"].waitForExistence(timeout: 10))
        attachScreenshot(named: "Pengambilan foto")
        app.buttons["Tutup"].tap()

        app.staticTexts["DAMIMAS_QA_BW_0001"].tap()
        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let measurements = app.buttons["Ukuran tandan"]
        for _ in 0..<3 where !measurements.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(measurements.isHittable)
        attachScreenshot(named: "Editor anotasi")
        measurements.tap()

        let weight = app.textFields["Berat (kg)"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.tap()
        weight.typeText("12")
        XCTAssertTrue(app.buttons["Terapkan"].isHittable)
        attachScreenshot(named: "Ukuran tandan dengan papan ketik")
        app.buttons["Terapkan"].tap()
        let results = app.buttons["Hasil"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        results.tap()
        let export = app.buttons["Siapkan berkas"]
        for _ in 0..<3 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isEnabled)
        export.tap()
        XCTAssertTrue(app.buttons["Bagikan CSV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Bagikan log anotasi"].exists)
        attachScreenshot(named: "Hasil dan ekspor")
    }

    @MainActor
    private func checkModuleScreens(orientation: UIDeviceOrientation) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments.append("--ui-test")
        app.launch()

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        attachScreenshot(named: "Pemilih modul")

        for module in ["Multisisi", "Multisisi Video", "Berat Tandan"] {
            let entry = list.staticTexts[module]
            for _ in 0..<5 where !entry.isHittable {
                list.swipeUp()
            }
            XCTAssertTrue(entry.isHittable, "Cannot reach \(module)")
            entry.tap()

            let navigation = app.navigationBars[module]
            XCTAssertTrue(navigation.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Belum ada sesi"].isHittable)
            attachScreenshot(named: module)
            navigation.buttons.firstMatch.tap()
        }
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
