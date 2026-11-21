import Foundation
import PalmCore
import Testing
import ZIPFoundation

@Suite struct ContractTests {
    private let photo = CapturedPhoto(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 100, height: 100)
    private let bounds = PixelBox(x1: 10, y1: 20, x2: 30, y2: 40)

    @Test func weightPackagePreservesLinksAndContracts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("store")
        let store = try PackageStore(root: root)
        let run = try await store.createRun(type: .bunchWeight, variety: "Damimas", block: "A 21B", operatorName: "Operator",
                                            sideCount: 2, split: "field", tokenized: false)
        try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
        try await store.saveDraftPhoto(photo, runID: run.id, side: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let gps = Provenance(status: .fresh, latitude: -3.3, longitude: 114.6,
                             fixTimeMillis: 1_699_999_939_000, provider: "test", source: "CURRENT_FIX")
        var result = try await store.commitCapture(runID: run.id, gps: gps, date: date)
        #expect(result.id == "DAMIMAS_A21B_BW_0001")
        #expect(result.gps.status == .stale)
        let firstBox = result.addBox(side: 0, rect: bounds)
        let secondBox = result.addBox(side: 1, rect: bounds)
        let a = try #require(firstBox)
        let b = try #require(secondBox)
        result.setMeasurements(a, Measurements(weightKg: 12, heightCm: 2, notes: " Grade, A "))
        result.setMeasurements(b, Measurements(weightKg: 5))
        let replaced = result.link(a, b)
        #expect(replaced)
        #expect(result.clusters == [[a, b]])
        #expect(result.annotation(b)?.measurements.weightKg == 12)
        result = try await store.save(result)
        #expect(result.isComplete)

        let reopened = try PackageStore(root: root)
        #expect(try await reopened.tree(id: result.id) == result)
        let initialToken = await store.deviceToken
        #expect(await reopened.deviceToken == initialToken)
        let labels = ExportCodec.labels(result.sides[0], type: .bunchWeight)
        #expect(String(decoding: labels, as: UTF8.self) == "0 0.200000 0.300000 0.200000 0.200000")
        let csv = String(decoding: ExportCodec.csv(result), as: UTF8.self)
        #expect(csv.hasSuffix("DAMIMAS_A21B_BW_0001,field,1,2,12.0,2.0,,\"Grade, A\""))
        let log = try json(ExportCodec.annotLog(result, side: result.sides[0]))
        let final = try #require(log["final"] as? [[String: Any]])
        #expect(final.first?["classId"] == nil)
        #expect(final.first?["bbox_pixel"] as? [Int] == [10, 20, 30, 40])
        let zip = try await reopened.export(runID: run.id, to: directory, appVersion: "test", date: date)
        let archive = try Archive(url: zip, accessMode: .read)
        let output = try data("json/\(result.id).json", archive: archive)
        let decoded = try ExportCodec.readOutput(output)
        #expect(decoded.images["side_1"]?.annotations[0].bbox_pixel == [10, 20, 30, 40])
        #expect(decoded._confirmedLinks.count == 1)
        let outputJSON = try json(output)
        let summary = try #require(outputJSON["summary"] as? [String: Any])
        #expect(summary["total_unique_bunches"] as? Int == 1)
        #expect(summary["by_class"] == nil)
        let metadata = try json(data("metadata/\(result.id).json", archive: archive))
        #expect(metadata["lat"] as? Double == -3.3)
        #expect((metadata["gps"] as? [String: Any])?["status"] as? String == "STALE")
        let manifest = try json(data("manifests/\(result.id).json", archive: archive))
        #expect(manifest["schemaVersion"] as? Int == 1)
        #expect(archive["capture_set.json"] != nil)
        #expect(archive["images/\(result.id)_1.jpg"] != nil)
        #expect(archive["labels/\(result.id)_2.txt"] != nil)

        result.unlink(result.links[0].id)
        #expect(result.clusters.count == 2)
        #expect(result.annotation(b)?.measurements.weightKg == 12)
        _ = result.addBox(side: 1, rect: bounds)
        #expect(try await reopened.save(result).isComplete == false)
    }

    @Test func earlyWeightFinishAndVideoGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PackageStore(root: directory)
        let weight = try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: "T1", operatorName: "",
                                               sideCount: 2, split: "field", tokenized: true)
        try await store.saveDraftPhoto(photo, runID: weight.id, side: 0)
        let weighted = try await store.commitCapture(runID: weight.id, gps: Provenance(status: .unavailable))
        #expect(weighted.sides.count == 1)
        #expect(weighted.id.contains("_BW_\(weight.captureSet.deviceToken)_"))
        let video = try await store.createRun(type: .multisideVideo, variety: "DAMIMAS", block: "T1", operatorName: "",
                                              sideCount: 4, split: "field", tokenized: false)
        for side in 0..<4 { try await store.saveDraftPhoto(photo, runID: video.id, side: side) }
        do {
            _ = try await store.commitCapture(runID: video.id, gps: Provenance(status: .unavailable))
            Issue.record("Video-less sample was accepted")
        } catch StoreError.videoRequired {
            #expect(try await store.draftPhotos(runID: video.id).count == 4)
        }
    }

    @Test func detectorDecodesAndSuppressesOverlaps() throws {
        let config = try JSONDecoder().decode(DetectorConfiguration.self, from:
            Data(#"{"modelFile":"test.onnx","inputSize":640,"confThreshold":0.01,"iouThreshold":0.3,"maxBoxes":300}"#.utf8))
        let letterbox = Letterbox(width: 1280, height: 640, size: 640)
        let rows: [Float] = [300, 240, 60, 30, 0.8, 301, 240, 60, 30, 0.7,
                             500, 300, 40, 20, 0.6, 50, 150, 10, 10, 0, 0, 0, 10, 10, 0, 0, 0, 10, 10, 0]
        let detections = YoloDetection.decode(rows, shape: [1, 6, 5], letterbox: letterbox, config: config)
        #expect(detections.map(\.id) == ["det0", "det1"])
        #expect(detections[0].rect == PixelBox(x1: 540, y1: 130, x2: 660, y2: 190))
    }

    @Test func publishedCaptureRecoversAnUnclearedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("store")
        let store = try PackageStore(root: root)
        let run = try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: "A21B", operatorName: "",
                                            sideCount: 1, split: "field", tokenized: false)
        try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
        let draft = root.appendingPathComponent("drafts").appendingPathComponent(run.id)
        let backup = directory.appendingPathComponent("interrupted-draft")
        try FileManager.default.copyItem(at: draft, to: backup)
        let first = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))

        try FileManager.default.moveItem(at: backup, to: draft)
        let reopened = try PackageStore(root: root)
        #expect(try await reopened.draftPhotos(runID: run.id).isEmpty)
        #expect(try await reopened.trees(runID: run.id).map(\.id) == [first.id])
        let revision = try await reopened.save(first)
        #expect(revision.revision == first.revision + 1)
        do {
            _ = try await reopened.save(first)
            Issue.record("An outdated revision was accepted")
        } catch StoreError.staleRevision {
            #expect(try await reopened.tree(id: first.id) == revision)
        }
        try await reopened.deleteTree(id: first.id)
        #expect(try await reopened.trees(runID: run.id).isEmpty)
    }

    @Test func readLegacyCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        let source = env["PALM_LEGACY_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../../Baseline-SawitMVC/ground_truth/annotations").standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        for file in files {
            let record = try ExportCodec.readOutput(Data(contentsOf: file))
            #expect(record.version == 4)
            #expect(!record.images.isEmpty)
        }
    }

    private func data(_ key: String, archive: Archive) throws -> Data {
        let entry = try #require(archive[key])
        var result = Data()
        _ = try archive.extract(entry) { result.append($0) }
        return result
    }

    private func json(_ bytes: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
}
