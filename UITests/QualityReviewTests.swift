import XCTest

/// The capture and export quality reviews ported from Kotlin `QualityGateModal`.
final class QualityReviewTests: XCTestCase {
    @MainActor
    func testQualityReviewInPortrait() {
        checkQualityReview(orientation: .portrait)
    }

    @MainActor
    func testQualityReviewInLandscape() {
        checkQualityReview(orientation: .landscapeLeft)
    }

    @MainActor
    private func checkQualityReview(orientation: UIDeviceOrientation) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", "--ui-test-quality"]
        app.launch()

        let module = app.staticTexts["Multisisi"]
        XCTAssertTrue(module.waitForExistence(timeout: 30))
        module.tap()
        app.staticTexts["DAMIMAS · QC"].tap()
        app.buttons.containing(.staticText, identifier: "Tangkap sampel").firstMatch.tap()

        // UI tests skip GPS, so saving the complete draft raises the missing-GPS warning.
        let save = app.buttons["Simpan sampel"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        reveal(save, in: app)
        save.tap()
        let gpsIssue = app.descendants(matching: .any)["quality-issue-metadata_gps_missing"]
        XCTAssertTrue(gpsIssue.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Lokasi GPS tidak tersedia. Tambahkan GPS untuk metadata yang lebih lengkap."].exists)
        XCTAssertTrue(app.staticTexts["Simpan tetap?"].exists)
        attachScreenshot(named: "Pemeriksaan kualitas tangkapan")

        app.buttons["Kembali perbaiki"].tap()
        XCTAssertTrue(gpsIssue.waitForNonExistence(timeout: 5))
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 / 4 foto"].exists, "Returning to fix must keep the draft")

        reveal(save, in: app)
        save.tap()
        let saveAnyway = app.buttons["Simpan tetap"]
        XCTAssertTrue(saveAnyway.waitForExistence(timeout: 5))
        saveAnyway.tap()

        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "Saving anyway must commit and open the sample")
        XCTAssertTrue(app.navigationBars["DAMIMAS_QC_0001"].exists)
        let complete = app.buttons["Selesaikan sampel"]
        reveal(complete, in: app)
        complete.tap()
        let status = app.staticTexts["save-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Sampel selesai dan tersimpan.")

        app.buttons["Hasil"].tap()
        let prepare = app.buttons["Siapkan berkas"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        reveal(prepare, in: app)
        prepare.tap()
        let emptyIssue = app.descendants(matching: .any)["quality-issue-annotation_empty"]
        XCTAssertTrue(emptyIssue.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 sisi belum memiliki anotasi bbox."].exists)
        attachScreenshot(named: "Pemeriksaan kualitas ekspor")

        app.buttons["Kembali perbaiki"].tap()
        XCTAssertTrue(emptyIssue.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Bagikan CSV"].exists, "Returning to fix must not export")

        reveal(prepare, in: app)
        prepare.tap()
        let exportAnyway = app.buttons["Ekspor tetap"]
        XCTAssertTrue(exportAnyway.waitForExistence(timeout: 5))
        exportAnyway.tap()
        XCTAssertTrue(app.buttons["Bagikan CSV"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Ekspor setelah pemeriksaan")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "Cannot reach \(element)")
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
