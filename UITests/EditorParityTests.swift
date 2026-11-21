import XCTest

/// Editor behaviours ported from Kotlin `CarouselScreen`, `DeduplicationScreen` and `MismatchResolveModal`.
final class EditorParityTests: XCTestCase {
    // MARK: Back

    @MainActor
    func testBackCompletesMultisisiSample() {
        let app = launch(.portrait, "--ui-test-quality")
        openMultisideEditor(app)
        let back = app.buttons["editor-back"]
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["4 foto · Selesai"].waitForExistence(timeout: 10),
                      "Back on a Multisisi sample saves and completes it, like Kotlin exitTree")
    }

    @MainActor
    func testBackKeepsWeightSampleAsDraftUntilWeightIsApplied() {
        let app = launch(.portrait, "--ui-test-capture")
        openWeightEditor(app)
        selectWeightBox(app)
        XCTAssertTrue(app.textFields["measurement-weight"].waitForExistence(timeout: 5),
                      "Selecting a box opens the weight panel without a further tap")
        app.buttons["editor-back"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Draf'")).firstMatch.waitForExistence(timeout: 10),
                      "A weight sample without a weight stays a draft")

        tapSample(app)
        selectWeightBox(app)
        let weight = app.textFields["measurement-weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 10))
        focus(weight, in: app)
        weight.typeText("12,5")
        app.buttons["measurement-apply"].tap()
        app.buttons["editor-back"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Selesai'")).firstMatch.waitForExistence(timeout: 10),
                      "A saved positive weight completes the sample")
    }

    // MARK: Weight panel

    @MainActor
    func testWeightPanelValidationInPortrait() {
        checkWeightPanel(.portrait)
    }

    @MainActor
    func testWeightPanelValidationInLandscape() {
        checkWeightPanel(.landscapeLeft)
    }

    @MainActor
    private func checkWeightPanel(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation, "--ui-test-capture")
        openWeightEditor(app)
        let photo = selectWeightBox(app)
        let weight = app.textFields["measurement-weight"]
        let apply = app.buttons["measurement-apply"]
        let error = app.staticTexts["measurement-error"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.exists, "The photo stays visible beside or above the panel")
        XCTAssertFalse(app.textFields["measurement-height"].exists, "Optional details start collapsed")

        apply.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(error.label, "Berat wajib diisi.")

        focus(weight, in: app)
        weight.typeText("0")
        XCTAssertTrue(apply.isHittable, "Apply stays reachable with the keyboard open")
        apply.tap()
        XCTAssertTrue(waitForLabel(error, "Berat harus lebih dari nol."))

        weight.typeText(XCUIKeyboardKey.delete.rawValue + "1,2,3")
        apply.tap()
        XCTAssertTrue(waitForLabel(error, "Berat harus berupa angka."))
        XCTAssertTrue(error.isHittable, "The message stays visible above the keyboard")
        attachScreenshot("Panel berat dengan pesan galat")

        weight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "12,5")
        let toggle = app.buttons["measurement-optional-toggle"]
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        toggle.tap()
        let circumference = app.textFields["measurement-circumference"]
        XCTAssertTrue(circumference.waitForExistence(timeout: 3))
        focus(circumference, in: app)
        circumference.typeText("0")
        XCTAssertTrue(apply.isHittable)
        apply.tap()
        XCTAssertTrue(waitForLabel(error, "Lingkar harus lebih dari nol bila diisi."))
        attachScreenshot("Detail opsional dengan papan ketik")

        circumference.typeText(XCUIKeyboardKey.delete.rawValue + "31")
        XCTAssertTrue(app.staticTexts["1 terisi"].exists)
        apply.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5), "A valid form is applied and the message clears")
    }

    @MainActor
    func testDraftSampleCanPrepareFilesWithKotlinNames() {
        let app = launch(.portrait, "--ui-test-capture")
        openWeightEditor(app)
        app.buttons["Hasil"].tap()
        let linked = app.descendants(matching: .any)["results-linked-duplicates"]
        XCTAssertTrue(linked.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Per sisi"].exists)
        let prepare = app.buttons["Siapkan berkas"]
        for _ in 0..<3 where !prepare.isHittable { app.swipeUp() }
        XCTAssertTrue(prepare.isEnabled, "A draft can be prepared too")
        prepare.tap()
        let exportAnyway = app.buttons["Ekspor tetap"]
        if exportAnyway.waitForExistence(timeout: 3) { exportAnyway.tap() }
        XCTAssertTrue(app.buttons["Bagikan CSV"].waitForExistence(timeout: 5))
    }

    // MARK: Dedup and mismatch

    @MainActor
    func testDedupAcceptsAutoRemovesLinkAndResolvesMismatchInPortrait() {
        checkDedup(.portrait)
    }

    @MainActor
    func testDedupAcceptsAutoRemovesLinkAndResolvesMismatchInLandscape() {
        checkDedup(.landscapeLeft)
    }

    @MainActor
    private func checkDedup(_ orientation: UIDeviceOrientation) {
        let app = launch(orientation, "--ui-test-quality")
        openMultisideEditor(app)

        // A bunch on each side of the seam between Foto 1 and Foto 2, the first one graded B1.
        drawBox(app, from: CGVector(dx: 0.02, dy: 0.35), to: CGVector(dx: 0.18, dy: 0.65))
        app.buttons["B1"].tap()
        app.buttons["Foto 2"].tap()
        drawBox(app, from: CGVector(dx: 0.82, dy: 0.35), to: CGVector(dx: 0.98, dy: 0.65))

        let dedup = app.buttons["open-dedup"]
        reveal(dedup, in: app)
        dedup.tap()
        XCTAssertTrue(app.navigationBars["Dedup"].waitForExistence(timeout: 5))
        let category = app.staticTexts["OTOMATIS"]
        XCTAssertTrue(category.waitForExistence(timeout: 5), "A strong seam match is categorised as automatic")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label MATCHES '[0-9]+%'")).firstMatch.exists)
        let acceptAuto = app.buttons["Terima semua otomatis (1)"]
        XCTAssertTrue(acceptAuto.isHittable)
        attachScreenshot("Dedup dengan saran otomatis")
        acceptAuto.tap()

        let confirmed = app.staticTexts["Tautan terkonfirmasi (1)"]
        XCTAssertTrue(confirmed.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tidak ada saran tautan untuk pasangan foto ini."].exists)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dedup-remove-link-'")).firstMatch
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(confirmed.waitForNonExistence(timeout: 5), "Removing a confirmed link takes it off the list")
        XCTAssertTrue(app.staticTexts["OTOMATIS"].waitForExistence(timeout: 5), "and the pair is suggested again")

        // Link again, then compute: Foto 1 is B1 and Foto 2 is unassigned, so the bunch needs a class.
        app.buttons["Terima semua otomatis (1)"].tap()
        XCTAssertTrue(confirmed.waitForExistence(timeout: 5))
        app.buttons["dedup-compute"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mismatch-body"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Foto 1 · B1"].exists)
        XCTAssertTrue(app.staticTexts["Foto 2 · U"].exists)
        XCTAssertTrue(app.buttons["mismatch-1-B1"].isSelected, "The majority class is preselected, and a tie takes the first member's class")
        app.buttons["mismatch-1-B3"].tap()
        attachScreenshot("Penyelesaian kelas tandan")
        app.buttons["mismatch-apply"].tap()

        XCTAssertTrue(app.navigationBars["Hasil"].waitForExistence(timeout: 10), "Applying continues to the results")
        XCTAssertFalse(app.staticTexts["Perbedaan kelas"].exists)
        XCTAssertEqual(app.staticTexts["results-linked-duplicates"].exists || app.descendants(matching: .any)["results-linked-duplicates"].exists, true)
        XCTAssertTrue(app.staticTexts["B3"].exists)
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ orientation: UIDeviceOrientation, _ fixture: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test", fixture]
        app.launch()
        return app
    }

    @MainActor
    private func openMultisideEditor(_ app: XCUIApplication) {
        let module = app.staticTexts["Multisisi"]
        XCTAssertTrue(module.waitForExistence(timeout: 90))
        module.tap()
        app.staticTexts["DAMIMAS · QC"].tap()
        app.buttons.containing(.staticText, identifier: "Tangkap sampel").firstMatch.tap()
        let save = app.buttons["Simpan sampel"]
        XCTAssertTrue(save.waitForExistence(timeout: 90))
        // The button stays disabled while the capture screen prepares the camera.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 90), .completed)
        reveal(save, in: app)
        save.tap()
        let saveAnyway = app.buttons["Simpan tetap"]
        XCTAssertTrue(saveAnyway.waitForExistence(timeout: 5))
        saveAnyway.tap()
        XCTAssertTrue(app.descendants(matching: .any)["annotation-photo"].firstMatch.waitForExistence(timeout: 90))
        XCTAssertTrue(app.navigationBars["DAMIMAS_QC_0001"].exists)
    }

    /// The sample row: its text is a separate element in portrait and part of the row's label in landscape.
    @MainActor
    private func sampleRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'DAMIMAS_QA_BW_0001'")).firstMatch
    }

    /// The session list is lazy and a landscape phone shows few rows, so scroll until the sample is built.
    @MainActor
    private func tapSample(_ app: XCUIApplication) {
        let sample = sampleRow(app)
        for _ in 0..<6 where !sample.waitForExistence(timeout: 5) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(sample.exists, "The sample row never appeared")
        sample.tap()
    }

    @MainActor
    private func openWeightEditor(_ app: XCUIApplication) {
        let module = app.staticTexts["Berat Tandan"]
        XCTAssertTrue(module.waitForExistence(timeout: 90))
        module.tap()
        app.staticTexts["DAMIMAS · QA"].tap()
        tapSample(app)
        XCTAssertTrue(app.descendants(matching: .any)["annotation-photo"].firstMatch.waitForExistence(timeout: 90))
    }

    @MainActor
    @discardableResult
    private func selectWeightBox(_ app: XCUIApplication) -> XCUIElement {
        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return photo
    }

    /// Draws a box in Edit mode; the new box stays selected.
    @MainActor
    private func drawBox(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let edit = app.segmentedControls.buttons["Edit"]
        if !edit.isSelected { edit.tap() }
        let draw = app.descendants(matching: .any)["Gambar kotak"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10))
        if draw.value as? String != "1" { draw.tap() }
        let photo = app.descendants(matching: .any)["annotation-photo"].firstMatch
        photo.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: to))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        if !element.isHittable { print(app.debugDescription) }
        XCTAssertTrue(element.isHittable, "Cannot reach \(element)")
    }

    /// Taps a field and waits for its keyboard; a slow simulator can swallow the first tap.
    @MainActor
    private func focus(_ field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Tapping the field opens the keyboard")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
