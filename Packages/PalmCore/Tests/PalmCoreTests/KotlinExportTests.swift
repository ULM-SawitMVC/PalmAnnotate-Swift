import CryptoKit
import Foundation
@testable import PalmCore
import Testing
import ZIPFoundation

@Suite struct KotlinExportTests {
    private struct Spec: Decodable {
        struct Box: Decodable {
            let side: Int
            let id: String
            let classId: Int
            let rect: [Float]
            let weight: Double?
            let height: Double?
            let circumference: Double?
            let notes: String?

            var bounds: PixelBox { PixelBox(x1: rect[0], y1: rect[1], x2: rect[2], y2: rect[3]) }
        }

        struct Link: Decodable {
            let a: BoxRef
            let b: BoxRef

            init(from decoder: any Decoder) throws {
                var values = try decoder.unkeyedContainer()
                a = try BoxRef(side: values.decode(Int.self), box: values.decode(String.self))
                b = try BoxRef(side: values.decode(Int.self), box: values.decode(String.self))
            }
        }

        let name: String
        let type: DatasetType
        let sideCount: Int
        let tokenized: Bool?
        let boxes: [Box]
        let links: [Link]
    }

    private struct Fixture {
        let spec: Spec
        let golden: [String: Any]
        let block: String

        let treeName: String
    }

    private let captureDate = Date(timeIntervalSince1970: 1_700_042_400)
    private var saveDate: Date { captureDate.addingTimeInterval(60) }
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExportFixtures")
    }

    @Test(arguments: ["multiside-4", "multiside-8", "video-4", "video-8", "weight-2", "weight-1"])
    func matchesPinnedKotlinPackage(_ name: String) async throws {
        let fixture = try load(name)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let tree = try await capture(fixture, in: store, directory: directory)
        let spec = fixture.spec
        let golden = fixture.golden
        let treeName = fixture.treeName

        #expect(tree.id == treeName)
        #expect(tree.isComplete)
        let csv = try #require(golden["csv"] as? String)
        #expect(ExportCodec.csv(tree) == Data(csv.utf8))
        try compare(parse(ExportCodec.identity(tree)), golden["identity"], at: "identity")
        let logs = try #require(golden["logs"] as? [[String: Any]])
        for side in tree.sides {
            try compare(parse(ExportCodec.annotLog(tree, side: side)), logs[side.id], at: "annotlog/\(side.id)")
        }

        let archiveURL = try await store.export(runID: tree.run.id, to: directory, appVersion: "test", date: saveDate)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let archivedPaths = archive.filter { $0.type == .file }.map(\.path).sorted()
        #expect(archivedPaths == golden["paths"] as? [String])

        let outputBytes = try archiveData("json/\(treeName).json", from: archive)
        let metadataBytes = try archiveData("metadata/\(treeName).json", from: archive)
        let manifestBytes = try archiveData("manifests/\(treeName).json", from: archive)
        let output = try parse(outputBytes)
        let metadata = try parse(metadataBytes)
        let manifest = try parse(manifestBytes)
        let descriptor = try parse(archiveData("capture_set.json", from: archive))

        let labels = try #require(golden["labels"] as? [String]).map { Data($0.utf8) }
        var photos: [Data] = []
        for side in tree.sides {
            let stem = "\(treeName)_\(side.id + 1)"
            let image = try archiveData("images/\(stem).jpg", from: archive)
            #expect(image == photoBytes(side.id))
            photos.append(image)
            #expect(try archiveData("labels/\(stem).txt", from: archive) == labels[side.id])
        }
        if spec.type.requiresVideo {
            let video = try archiveData("video/\(treeName).mp4", from: archive)
            #expect(video == videoBytes)
            #expect(tree.video?.sha256 == hash(video))
            #expect(tree.video?.sizeBytes == UInt64(video.count))
        }

        let identity = tree.run.captureSet.captureSetId
        var expectedOutput = try #require(golden["output"] as? [String: Any])
        var expectedOutputMetadata = try #require(expectedOutput["metadata"] as? [String: Any])
        expectedOutputMetadata["capture_set_id"] = identity
        // Kotlin goldens use a fixed local day. PackageStore derives the day in the host time zone.
        let localDay = ExportCodec.captureDate(captureDate)
        let sessionID = try #require(expectedOutputMetadata["session_id"] as? String)
        expectedOutputMetadata["session_id"] = localDay.replacingOccurrences(of: "-", with: "") + sessionID.dropFirst(8)
        expectedOutputMetadata["date"] = localDay
        expectedOutput["metadata"] = expectedOutputMetadata
        try compare(output, expectedOutput, at: "output")

        var expectedMetadata = try #require(golden["metadata"] as? [String: Any])
        expectedMetadata["captureDate"] = localDay
        expectedMetadata["captureSet"] = try captureSet(in: expectedMetadata, with: identity)
        try compare(metadata, expectedMetadata, at: "metadata")

        let kotlinManifest = try #require(golden["manifest"] as? [String: Any])
        let kotlinDescriptor = try #require(golden["descriptor"] as? [String: Any])
        let kotlinOutputBytes = Data(try #require(golden["outputText"] as? String).utf8)
        let kotlinMetadataBytes = Data(try #require(golden["metadataText"] as? String).utf8)
        let kotlinManifestBytes = Data(try #require(golden["manifestText"] as? String).utf8)
        try verifyDigests(kotlinManifest, kotlinDescriptor, output: kotlinOutputBytes, metadata: kotlinMetadataBytes,
                          manifestBytes: kotlinManifestBytes, photos: photos, labels: labels)
        try verifyDigests(manifest, descriptor, output: outputBytes, metadata: metadataBytes,
                          manifestBytes: manifestBytes, photos: photos, labels: labels)

        var expectedManifest = kotlinManifest
        expectedManifest["captureSet"] = try captureSet(in: expectedManifest, with: identity)
        expectedManifest["annotationRevision"] = manifest["annotationRevision"]
        for key in ["outputJson", "metadata"] {
            var reference = try #require(kotlinManifest[key] as? [String: Any])
            reference["sha256"] = (manifest[key] as? [String: Any])?["sha256"]
            expectedManifest[key] = reference
        }
        try compare(manifest, expectedManifest, at: "manifest")

        var expectedDescriptor = kotlinDescriptor
        expectedDescriptor["captureSetId"] = identity
        var expectedTrees = try #require(kotlinDescriptor["trees"] as? [[String: Any]])
        expectedTrees[0]["captureSetId"] = identity
        expectedTrees[0]["contentDigest"] = hash(manifestBytes)
        expectedDescriptor["trees"] = expectedTrees
        try compare(descriptor, expectedDescriptor, at: "capture_set")

        let token = await store.deviceToken
        let archiveName = try Regex("DAMIMAS_\(fixture.block)_\(token)_[0-9]{8}-[0-9]{6}\\.zip")
        #expect(archiveURL.lastPathComponent.wholeMatch(of: archiveName) != nil)
        if let destination = ProcessInfo.processInfo.environment["PALM_EXPORT_TEST_ZIPS"] {
            let target = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.copyItem(at: archiveURL, to: target.appendingPathComponent("\(name).zip"))
        }
    }

    @Test func exportRejectsChangedRGBWithoutEditingTheSnapshot() async throws {
        let fixture = try load("weight-1")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let tree = try await capture(fixture, in: store, directory: directory)
        let photo = await store.photoURL(treeID: tree.id, side: 0)
        try photoBytes(1).write(to: photo)

        await #expect(throws: (any Error).self) {
            try await store.export(runID: tree.run.id, to: directory, appVersion: "test", date: saveDate)
        }
        #expect(try await store.tree(id: tree.id) == tree)
        #expect(try Data(contentsOf: photo) == photoBytes(1))
        try photoBytes(0).write(to: photo)
        let zip = try await store.export(runID: nil, to: directory, appVersion: "test", date: saveDate)
        #expect(zip.lastPathComponent.hasPrefix("PalmAnnotate_all_"))
    }

    private func capture(_ fixture: Fixture, in store: PackageStore, directory: URL) async throws -> TreeDocument {
        let spec = fixture.spec
        let operatorName = spec.name == "multiside-4" ? "  Operator A  " : ""
        let run = try await store.createRun(type: spec.type, variety: "Damimas", block: fixture.block,
                                            operatorName: operatorName, sideCount: spec.sideCount == 1 ? 2 : spec.sideCount,
                                            split: spec.type.requiresVideo ? "test" : "field", tokenized: spec.tokenized ?? false)
        for side in 0..<spec.sideCount {
            let suggestions = spec.boxes.filter { $0.side == side && $0.id.hasPrefix("det") }
                .map { Annotation(id: $0.id, rect: $0.bounds) }
            try await store.saveDraftPhoto(CapturedPhoto(jpeg: photoBytes(side), width: 1024, height: 1024,
                                                        suggestions: suggestions), runID: run.id, side: side)
        }
        if spec.type.requiresVideo {
            let video = directory.appendingPathComponent("source.mp4")
            try videoBytes.write(to: video)
            try await store.saveDraftVideo(from: video, runID: run.id)
        }
        let gps: Provenance
        switch spec.name {
        case "multiside-4":
            gps = Provenance(status: .fresh, latitude: -3.3, longitude: 114.6, accuracyM: 3.1,
                             fixTimeMillis: Int64(captureDate.timeIntervalSince1970 * 1000) - 61_000,
                             provider: "gps", source: "CURRENT_FIX")
        case "video-8":
            gps = Provenance(status: .permissionDenied)
        default:
            gps = Provenance(status: .unavailable)
        }
        var tree = try await store.commitCapture(runID: run.id, gps: gps, date: captureDate)
        for box in spec.boxes {
            let ref = BoxRef(side: box.side, box: box.id)
            if !box.id.hasPrefix("det") { #expect(tree.addBox(side: box.side, rect: box.bounds) == ref) }
            tree.setRipeness(ref, ripeness: try #require(Ripeness(rawValue: box.classId)))
            var measurements = Measurements(weightKg: box.weight, heightCm: box.height,
                                            circumferenceCm: box.circumference)
            measurements.notes = box.notes
            tree.setMeasurements(ref, measurements)
        }
        for link in spec.links {
            #expect(tree.canLink(link.a, link.b))
            tree.link(link.a, link.b)
        }
        return try await store.save(tree, markComplete: true, date: saveDate)
    }

    private func load(_ name: String) throws -> Fixture {
        let cases = try JSONDecoder().decode([Spec].self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("cases.json")))
        let index = try #require(cases.firstIndex { $0.name == name })
        let golden = try parse(Data(contentsOf: fixtureDirectory.appendingPathComponent("\(name).json")))
        let treeName = try #require(golden["tree"] as? String)
        return Fixture(spec: cases[index], golden: golden, block: "QA\(index + 1)", treeName: treeName)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore(in directory: URL) throws -> PackageStore {
        let root = directory.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic-palm-export-install".utf8).write(to: root.appendingPathComponent("install-id"))
        return try PackageStore(root: root)
    }

    private func photoBytes(_ side: Int) -> Data { Data([0xff, 0xd8, UInt8(side), 0xff, 0xd9]) }
    private var videoBytes: Data { Data([0, 0, 0, 8, 102, 114, 101, 101]) }

    private func parse(_ bytes: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func compare(_ actual: Any?, _ expected: Any?, at path: String) throws {
        switch (actual, expected) {
        case let (actual as [String: Any], expected as [String: Any]):
            #expect(Set(actual.keys) == Set(expected.keys), "\(path)")
            for key in actual.keys.filter({ expected.keys.contains($0) }).sorted() {
                try compare(actual[key], expected[key], at: "\(path).\(key)")
            }
        case let (actual as [Any], expected as [Any]):
            #expect(actual.count == expected.count, "\(path)")
            for (index, values) in zip(actual, expected).enumerated() {
                try compare(values.0, values.1, at: "\(path)[\(index)]")
            }
        default:
            let actualValue = try JSONSerialization.data(withJSONObject: actual ?? NSNull(), options: [.fragmentsAllowed])
            let expectedValue = try JSONSerialization.data(withJSONObject: expected ?? NSNull(), options: [.fragmentsAllowed])
            #expect(String(decoding: actualValue, as: UTF8.self) == String(decoding: expectedValue, as: UTF8.self), "\(path)")
        }
    }

    private func captureSet(in document: [String: Any], with id: String) throws -> [String: Any] {
        var expected = try #require(document["captureSet"] as? [String: Any])
        expected["captureSetId"] = id
        return expected
    }

    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func verifyDigests(_ manifest: [String: Any], _ descriptor: [String: Any], output: Data, metadata: Data,
                               manifestBytes: Data, photos: [Data], labels: [Data]) throws {
        let outputHash = hash(output)
        let labelHashes = labels.map(hash)
        let imageHashes = photos.map(hash)
        let rgbSet = imageHashes.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: "|")
        let annotation = ([outputHash] + labelHashes).joined(separator: "|")
        #expect(manifest["captureSetId"] as? String == hash(Data(rgbSet.utf8)))
        #expect((manifest["captureSet"] as? [String: Any])?["captureSetId"] as? String != manifest["captureSetId"] as? String)
        #expect(manifest["annotationRevision"] as? String == hash(Data(annotation.utf8)))
        #expect((manifest["outputJson"] as? [String: Any])?["sha256"] as? String == outputHash)
        #expect((manifest["metadata"] as? [String: Any])?["sha256"] as? String == hash(metadata))
        let sides = try #require(manifest["sides"] as? [[String: Any]])
        try #require(sides.count == photos.count)
        for (index, side) in sides.enumerated() {
            #expect(side["sideIndex"] as? Int == index)
            #expect((side["rgb"] as? [String: Any])?["sha256"] as? String == imageHashes[index])
            #expect((side["label"] as? [String: Any])?["sha256"] as? String == labelHashes[index])
        }
        let entries = try #require(descriptor["trees"] as? [[String: Any]])
        #expect(entries.first?["contentDigest"] as? String == hash(manifestBytes))
    }

    private func archiveData(_ path: String, from archive: Archive) throws -> Data {
        let entry = try #require(archive[path])
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return bytes
    }
}
