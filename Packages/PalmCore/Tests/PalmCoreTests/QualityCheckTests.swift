import Foundation
import PalmCore
import Testing

/// Ports `QualityCheckTest` from Kotlin `DomainTests.kt` at a52a5cb, plus the iOS call sites.
@Suite struct QualityCheckTests {
    private let photo = CapturedPhoto(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1000, height: 1000)
    private let box = PixelBox(x1: 0, y1: 0, x2: 100, y2: 100)

    // MARK: Capture pre-save

    @Test func captureAllGoodIsOK() {
        let report = QualityCheck.analyzeCaptureShots(capturedSides: 4, expectedSides: 4, depthSides: 4,
                                                      hasGps: true, hasVariety: true, hasBlock: true)
        #expect(report.status == .ok)
        #expect(report.issues.isEmpty)
        #expect(!report.needsReview)
    }

    @Test func captureMissingVarietyIsError() {
        let report = QualityCheck.analyzeCaptureShots(capturedSides: 4, expectedSides: 4, depthSides: 4,
                                                      hasGps: true, hasVariety: false, hasBlock: true)
        #expect(report.status == .error)
        #expect(report.issues.contains { $0.code == "metadata_variety_missing" })
    }

    @Test func captureMissingSidesIsErrorAndMissingGpsOnlyWarn() {
        let missingSides = QualityCheck.analyzeCaptureShots(capturedSides: 2, expectedSides: 4, depthSides: 2,
                                                            hasGps: true, hasVariety: true, hasBlock: true)
        #expect(missingSides.status == .error)
        let noGps = QualityCheck.analyzeCaptureShots(capturedSides: 4, expectedSides: 4, depthSides: 4,
                                                     hasGps: false, hasVariety: true, hasBlock: true)
        #expect(noGps.status == .warn)
    }

    @Test func tabletRGBOnlyCaptureDoesNotRequireDepth() {
        let report = QualityCheck.analyzeCaptureShots(capturedSides: 4, expectedSides: 4, depthSides: 0,
                                                      requiredDepthSides: 0, hasGps: true, hasVariety: true, hasBlock: true)
        #expect(report.status == .ok)
        #expect(!report.issues.contains { $0.code == "capture_rgb_depth_incomplete" })
    }

    @Test func orbbecCaptureWarnsWhenAnyRequiredDepthIsMissing() {
        let report = QualityCheck.analyzeCaptureShots(capturedSides: 4, expectedSides: 4, depthSides: 1,
                                                      requiredDepthSides: 2, hasGps: true, hasVariety: true, hasBlock: true)
        #expect(report.status == .warn)
        #expect(report.issues.contains { $0.code == "capture_rgb_depth_incomplete" })
    }

    @Test func captureIssuesKeepKotlinOrderMessagesAndMetrics() {
        let report = QualityCheck.analyzeCaptureShots(capturedSides: 3, expectedSides: 4, depthSides: 1,
                                                      hasGps: false, hasVariety: false, hasBlock: false)
        #expect(report.issues.map(\.code) == ["capture_view_missing", "capture_rgb_depth_incomplete",
                                              "metadata_gps_missing", "metadata_variety_missing", "metadata_block_missing"])
        #expect(report.issues.map(\.level) == [.error, .warn, .warn, .error, .warn])
        #expect(report.issues.map(\.message) == [
            "Hanya 3 dari 4 sisi yang berhasil ditangkap.",
            "Hanya 1 dari 3 foto Orbbec yang memiliki data depth.",
            "Lokasi GPS tidak tersedia. Tambahkan GPS untuk metadata yang lebih lengkap.",
            "Metadata variety belum terisi.",
            "Metadata block belum terisi.",
        ])
        #expect(report.metrics == ["capturedSides": 3, "expectedSides": 4, "depthSides": 1, "requiredDepthSides": 3])
    }

    @Test func iosCaptureGateUsesTakenWeightPhotosAndAnyRecordedCoordinate() async throws {
        try await withStore { store in
            let weight = try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: "T1", operatorName: "",
                                                   sideCount: 2, split: "field", tokenized: false)
            let stale = Provenance(status: .stale, latitude: -3.3, longitude: 114.6, fixTimeMillis: 0)
            let early = QualityCheck.analyzeCapture(run: weight, capturedSides: 1, gps: stale)
            #expect(early.status == .ok)
            #expect(early.metrics["expectedSides"] == 1)

            let multiside = try await store.createRun(type: .multiside, variety: "DAMIMAS", block: "T1", operatorName: "",
                                                      sideCount: 4, split: "field", tokenized: false)
            let denied = QualityCheck.analyzeCapture(run: multiside, capturedSides: 4, gps: Provenance(status: .permissionDenied))
            #expect(denied.status == .warn)
            #expect(denied.issues.map(\.code) == ["metadata_gps_missing"])
            #expect(denied.needsReview)
            #expect(QualityCheck.analyzeCapture(run: multiside, capturedSides: 3, gps: stale).status == .error)
        }
    }

    // MARK: Tree QA

    @Test func emptySessionSurfacesVarietyErrorWithoutCrashing() async throws {
        try await withStore { store in
            let tree = try await multisideTree(store, sides: 1)
            let empty = try rewrite(tree) { json in
                json["sides"] = []
                var run = json["run"] as! [String: Any]
                run["variety"] = " "
                run["block"] = ""
                json["run"] = run
            }
            let report = QualityCheck.analyzeTree(empty)
            #expect(report.status == .error)
            #expect(report.metrics["totalSides"] == 0)
            #expect(report.issues.map(\.code) == ["metadata_variety_missing", "metadata_block_missing"])
        }
    }

    @Test func treeWithMetadataAndLinksHasNoErrorIssues() async throws {
        try await withStore { store in
            var tree = try await multisideTree(store, sides: 2)
            let aAdded = tree.addBox(side: 0, rect: box)
            let a = try #require(aAdded)
            let bAdded = tree.addBox(side: 1, rect: box)
            let b = try #require(bAdded)
            tree.setRipeness(a, ripeness: .b1)
            tree.setRipeness(b, ripeness: .b1)
            tree.link(a, b)
            let report = QualityCheck.analyzeTree(tree)
            #expect(!report.issues.contains { $0.level == .error })
            #expect(report.metrics["mismatches"] == 0)
            #expect(report.status == .ok)
            #expect(report.metrics == ["totalSides": 2, "totalBboxes": 2, "unassigned": 0, "links": 1, "mismatches": 0])
        }
    }

    @Test func classMismatchAcrossLinkedClusterIsError() async throws {
        try await withStore { store in
            var tree = try await multisideTree(store, sides: 2)
            let aAdded = tree.addBox(side: 0, rect: box)
            let a = try #require(aAdded)
            let bAdded = tree.addBox(side: 1, rect: box)
            let b = try #require(bAdded)
            tree.setRipeness(a, ripeness: .b1)
            tree.setRipeness(b, ripeness: .b3)
            tree.link(a, b)
            let report = QualityCheck.analyzeTree(tree)
            #expect(report.status == .error)
            #expect(report.issues.contains {
                $0.code == "annotation_class_mismatch" && $0.message == "1 bunch memiliki kelas yang tidak konsisten antar sisi."
            })
        }
    }

    @Test func unassignedBoxRaisesWarning() async throws {
        try await withStore { store in
            var tree = try await multisideTree(store, sides: 1)
            tree.addBox(side: 0, rect: box)
            let report = QualityCheck.analyzeTree(tree)
            #expect(report.status == .warn)
            #expect(report.issues.map(\.message) == ["1 bbox belum diberi kelas (unassigned)."])
            #expect(report.metrics["unassigned"] == 1)
        }
    }

    @Test func tinyBoxRaisesInfoOnly() async throws {
        try await withStore { store in
            var tree = try await multisideTree(store, sides: 1)
            let refAdded = tree.addBox(side: 0, rect: PixelBox(x1: 0, y1: 0, x2: 5, y2: 5))
            let ref = try #require(refAdded)
            tree.setRipeness(ref, ripeness: .b2)
            let report = QualityCheck.analyzeTree(tree)
            #expect(report.issues.count == 1)
            #expect(report.issues.first?.code == "annotation_tiny_bbox")
            #expect(report.issues.first?.level == .info)
            #expect(report.issues.first?.message == "1 bbox sangat kecil (< 10×10 px). Periksa apakah sudah benar.")
            #expect(report.status == .ok)
            #expect(!report.needsReview)
        }
    }

    @Test func emptySidesAndMissingLinksWarn() async throws {
        try await withStore { store in
            var tree = try await multisideTree(store, sides: 4)
            for side in 0..<2 {
                let refAdded = tree.addBox(side: side, rect: box)
                let ref = try #require(refAdded)
                tree.setRipeness(ref, ripeness: .b4)
            }
            let report = QualityCheck.analyzeTree(tree)
            #expect(report.status == .warn)
            #expect(report.issues.map(\.message) == [
                "2 sisi belum memiliki anotasi bbox.",
                "Belum ada link cross-side. Gunakan Dedup untuk menghubungkan bunch yang sama.",
            ])
        }
    }

    @Test func bunchWeightDoesNotReportRipenessAsUnassigned() async throws {
        try await withStore { store in
            let run = try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: "QA", operatorName: "",
                                                sideCount: 2, split: "field", tokenized: false)
            try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
            var tree = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
            let refAdded = tree.addBox(side: 0, rect: box)
            let ref = try #require(refAdded)
            tree.setMeasurements(ref, Measurements(weightKg: 12))
            let report = QualityCheck.analyzeTree(tree)
            #expect(report.status == .ok)
            #expect(report.metrics["unassigned"] == 0)
        }
    }

    // MARK: Helpers

    private func withStore(_ body: (PackageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(PackageStore(root: directory))
    }

    private func multisideTree(_ store: PackageStore, sides: Int) async throws -> TreeDocument {
        let run = try await store.createRun(type: .multiside, variety: "Tenera", block: "A1", operatorName: "",
                                            sideCount: 4, split: "field", tokenized: false)
        for side in 0..<4 { try await store.saveDraftPhoto(photo, runID: run.id, side: side) }
        let tree = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
        // Kotlin's tests build one- and two-side sessions; the store only commits a full multiside capture.
        return try rewrite(tree) { json in json["sides"] = Array((json["sides"] as! [Any]).prefix(sides)) }
    }

    private func rewrite(_ tree: TreeDocument, _ change: (inout [String: Any]) -> Void) throws -> TreeDocument {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tree)) as! [String: Any]
        change(&json)
        return try JSONDecoder().decode(TreeDocument.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
