import XCTest

/// Run deletion, ZIP export progress and sharing, fixed weight photo slots, manual IDs, and the hub footer.
final class CollectionParityTests: XCTestCase {
    @MainActor
    private func launch(_ orientation: UIDeviceOrientation, _ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "\(element) is not reachable")
    }

    @MainActor
    private func openModule(_ name: String, in app: XCUIApplication) {
        let entry = app.collectionViews.firstMatch.staticTexts[name]
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
    }

    // MARK: Hub

    @MainActor func testHubFooterInPortrait() { checkHubFooter(.portrait) }
    @MainActor func testHubFooterInLandscape() { checkHubFooter(.landscapeLeft) }

    @MainActor
    private func checkHubFooter(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation)
        let version = app.staticTexts["hub-version"]
        XCTAssertTrue(version.waitForExistence(timeout: 30))
        XCTAssertTrue(version.isHittable)
        XCTAssertTrue(version.label.hasPrefix("v0.1.0 ("), version.label)
        XCTAssertTrue(version.label.hasSuffix(")"))
        XCTAssertEqual(app.staticTexts["hub-data-hint"].label, "Data hanya tersimpan di aplikasi ini. Ekspor ZIP untuk memindahkan data.")
        XCTAssertTrue(app.staticTexts["hub-data-hint"].isHittable)
    }

    // MARK: New session form

    @MainActor func testWeightFormHasFixedPhotoSlotsInPortrait() { checkWeightForm(.portrait) }
    @MainActor func testWeightFormHasFixedPhotoSlotsInLandscape() { checkWeightForm(.landscapeLeft) }

    @MainActor
    private func checkWeightForm(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation)
        openModule("Berat Tandan", in: app)
        app.buttons["Sesi baru"].tap()
        XCTAssertTrue(app.textFields["Varietas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["ID otomatis"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Jumlah foto"].exists, "The weight form must not offer a photo count")
        app.buttons["Batal"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        openModule("Multisisi", in: app)
        app.buttons["Sesi baru"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Jumlah foto"].waitForExistence(timeout: 5))
    }

    @MainActor func testManualIdToggleInPortrait() { checkManualId(.portrait) }
    @MainActor func testManualIdToggleInLandscape() { checkManualId(.landscapeLeft) }

    @MainActor
    private func checkManualId(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation)
        openModule("Multisisi", in: app)
        app.buttons["Sesi baru"].tap()
        let variety = app.textFields["Varietas"]
        XCTAssertTrue(variety.waitForExistence(timeout: 5))
        variety.tap()
        variety.typeText("TEST")
        let block = app.textFields["Blok"]
        block.tap()
        block.typeText("M1\n")
        let toggle = app.switches["ID otomatis"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let off = NSPredicate(format: "value == '0'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: off, evaluatedWith: toggle)], timeout: 10), .completed)
        let note = app.staticTexts["Nomor pohon diketik sendiri saat pengambilan."]
        for _ in 0..<3 where !note.exists { app.swipeUp() }
        XCTAssertTrue(note.exists)
        app.buttons["Simpan"].tap()
        // The run header only lists the ID mode for manual runs.
        let row = app.staticTexts["ID pohon"]
        XCTAssertTrue(row.waitForExistence(timeout: 10) || { app.swipeUp(); return row.waitForExistence(timeout: 5) }())
    }

    // MARK: Run list

    @MainActor func testRunListStatsDeleteAndSortInPortrait() { checkRunList(.portrait) }
    @MainActor func testRunListStatsDeleteAndSortInLandscape() { checkRunList(.landscapeLeft) }

    @MainActor
    private func checkRunList(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation, ["--ui-test-collections"])
        openModule("Multisisi", in: app)
        let kept = app.staticTexts["DAMIMAS · A1"]
        let doomed = app.staticTexts["DAMIMAS · B2"]
        XCTAssertTrue(kept.waitForExistence(timeout: 10))
        XCTAssertTrue(doomed.exists)
        XCTAssertTrue(app.staticTexts["2 pohon · 4 foto/pohon"].exists)
        XCTAssertTrue(app.staticTexts["0 pohon · 4 foto/pohon"].exists)
        let stats = app.descendants(matching: .any)["run-stats"]
        XCTAssertTrue(stats.exists)
        for label in ["Sesi", "Pohon", "Foto"] { XCTAssertTrue(stats.staticTexts[label].exists, label) }
        XCTAssertTrue(stats.staticTexts["8"].exists, "2 trees x 4 photos")
        // The session written most recently comes first: A1 holds the seeded trees.
        XCTAssertLessThan(kept.frame.minY, doomed.frame.minY)

        doomed.swipeLeft()
        app.buttons["Hapus"].firstMatch.tap()
        let alert = app.alerts["Hapus sesi?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.element(boundBy: 1).label.contains("Hapus DAMIMAS · B2 beserta 0 pohon"))
        alert.buttons["Hapus"].tap()
        XCTAssertTrue(app.staticTexts["DAMIMAS · B2"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DAMIMAS · A1"].exists)

        // The trees of a deleted run go with it.
        app.staticTexts["DAMIMAS · A1"].press(forDuration: 1.2)
        app.buttons["Hapus"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Hapus sesi?"].staticTexts.element(boundBy: 1).label.contains("beserta 2 pohon"))
        app.alerts["Hapus sesi?"].buttons["Hapus"].tap()
        XCTAssertTrue(app.staticTexts["Belum ada sesi"].waitForExistence(timeout: 5))
    }

    // MARK: Export

    @MainActor func testExportAllProgressCancelAndShareInPortrait() { checkExportAll(.portrait) }
    @MainActor func testExportAllProgressCancelAndShareInLandscape() { checkExportAll(.landscapeLeft) }

    @MainActor
    private func checkExportAll(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation, ["--ui-test-collections", "--ui-test-slow-export"])
        openModule("Multisisi", in: app)
        XCTAssertTrue(app.staticTexts["DAMIMAS · A1"].waitForExistence(timeout: 10))
        app.buttons["Ekspor semua ZIP"].tap()
        app.alerts["Ekspor seluruh dataset?"].buttons["Ekspor semua ZIP"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["export-progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Menyiapkan ZIP…"].exists)
        app.buttons["Batal"].tap()
        XCTAssertTrue(app.staticTexts["Ekspor dibatalkan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["export-ready"].exists)

        app.buttons["Ekspor semua ZIP"].tap()
        app.alerts["Ekspor seluruh dataset?"].buttons["Ekspor semua ZIP"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["export-progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(dismissShareSheet(app), "The share sheet must open by itself when the ZIP is ready")
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ZIP siap: PalmAnnotate_all_'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 10), "The ZIP confirmation never appeared")
    }

    @MainActor func testRunExportIncludesDraftSamplesInPortrait() { checkRunExport(.portrait) }
    @MainActor func testRunExportIncludesDraftSamplesInLandscape() { checkRunExport(.landscapeLeft) }

    @MainActor
    private func checkRunExport(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation, ["--ui-test-collections"])
        openModule("Multisisi", in: app)
        app.staticTexts["DAMIMAS · A1"].tap()
        let make = app.buttons["Buat ZIP"]
        for _ in 0..<6 where !make.isHittable { app.collectionViews.firstMatch.swipeUp() }
        make.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(dismissShareSheet(app), "The seeded samples are drafts and must still export and open the share sheet")
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ZIP siap: DAMIMAS_A1_'")).firstMatch
        for _ in 0..<3 where !ready.exists { app.swipeDown() }
        XCTAssertTrue(ready.waitForExistence(timeout: 10), "The ZIP confirmation never appeared")
        XCTAssertTrue(app.buttons["Bagikan ZIP"].exists)
    }

    @MainActor
    @discardableResult
    private func dismissShareSheet(_ app: XCUIApplication) -> Bool {
        let sheet = app.otherElements["ActivityListView"]
        guard sheet.waitForExistence(timeout: 60) else { return false }
        let close = app.buttons["Close"]
        if close.exists { close.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap() }
        _ = sheet.waitForNonExistence(timeout: 5)
        return true
    }
}
