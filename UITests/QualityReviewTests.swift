import XCTest

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

        let save = app.buttons["Simpan sampel"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.reveal(scrolling: app)
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

        save.reveal(scrolling: app)
        save.tap()
        let saveAnyway = app.buttons["Simpan tetap"]
        XCTAssertTrue(saveAnyway.waitForExistence(timeout: 5))
        saveAnyway.tap()

        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "Saving anyway must commit and open the sample")
        XCTAssertTrue(app.navigationBars["DAMIMAS_QC_0001"].exists)

        app.buttons["Hasil"].tap()
        XCTAssertTrue(app.navigationBars["Hasil"].waitForExistence(timeout: 5))
        let prepare = app.buttons["Siapkan berkas"]
        prepare.reveal(scrolling: app.collectionViews["results-list"])
        prepare.tap()
        let emptyIssue = app.descendants(matching: .any)["quality-issue-annotation_empty"]
        XCTAssertTrue(emptyIssue.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 sisi belum memiliki anotasi bbox."].exists)
        attachScreenshot(named: "Pemeriksaan kualitas ekspor")

        app.buttons["Kembali perbaiki"].tap()
        XCTAssertTrue(emptyIssue.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Bagikan CSV"].exists, "Returning to fix must not export")

        prepare.reveal(scrolling: app.collectionViews["results-list"])
        prepare.tap()
        let exportAnyway = app.buttons["Ekspor tetap"]
        XCTAssertTrue(exportAnyway.waitForExistence(timeout: 5))
        exportAnyway.tap()
        XCTAssertTrue(app.buttons["Bagikan CSV"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Ekspor setelah pemeriksaan")
    }
}
