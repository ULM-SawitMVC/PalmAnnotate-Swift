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
        XCTAssertTrue(app.buttons["Pilih foto simulator"].waitForNonExistence(timeout: 10))

        let sample = app.staticTexts["DAMIMAS_QA_BW_0001"]
        for _ in 0..<5 where !sample.exists || !sample.isHittable { app.collectionViews.firstMatch.swipeUp() }
        sample.tap()
        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        attachScreenshot(named: "Editor anotasi")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let weight = app.textFields["measurement-weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.tap()
        weight.typeText("12")
        let apply = app.buttons["measurement-apply"]
        XCTAssertTrue(apply.isHittable)
        attachScreenshot(named: "Ukuran tandan dengan papan ketik")
        apply.tap()
        let results = app.buttons["Hasil"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        results.tap()
        XCTAssertTrue(app.navigationBars["Hasil"].waitForExistence(timeout: 5))
        let export = app.buttons["Siapkan berkas"]
        for _ in 0..<6 where !export.exists || !export.isHittable { app.collectionViews["results-list"].swipeUp() }
        XCTAssertTrue(export.isEnabled)
        export.tap()
        XCTAssertTrue(app.buttons["Bagikan CSV"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Hasil dan ekspor")
        for title in ["Bagikan Identity JSON", "Bagikan log anotasi", "Bagikan Output JSON", "Bagikan label YOLO"] {
            app.buttons[title].reveal(scrolling: app.collectionViews["results-list"])
        }
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
            let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Belum ada sesi")).firstMatch
            XCTAssertTrue(empty.isHittable)
            attachScreenshot(named: module)
            navigation.buttons.firstMatch.tap()
        }
    }
}
