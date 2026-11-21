import Foundation
import PalmCore
import Testing
import ZIPFoundation

/// Run deletion, run-list summaries, export progress, manual tree IDs, and the draft photo layout.
@Suite struct StoreParityTests {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
    private var photo: CapturedPhoto { CapturedPhoto(jpeg: jpeg, width: 100, height: 100) }

    private func withStore(_ body: (PackageStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("store")
        try await body(PackageStore(root: root), root)
    }

    private func weightRun(_ store: PackageStore, block: String = "A1", autoId: Bool = true) async throws -> CollectionRun {
        try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: block, operatorName: "",
                                  sideCount: 2, split: "field", tokenized: false, autoId: autoId)
    }

    private func commit(_ store: PackageStore, _ run: CollectionRun, number: Int? = nil,
                        date: Date = .now) async throws -> TreeDocument {
        try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
        return try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable), treeNumber: number, date: date)
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Int, Int, String)] = []
        var all: [(Int, Int, String)] { lock.withLock { values } }
        func add(_ done: Int, _ total: Int, _ name: String) { lock.withLock { values.append((done, total, name)) } }
    }

    @Test func varietyWithoutUsableCharactersBecomesTreeButBlankIsRefused() async throws {
        #expect(CollectionRun.sanitizedVariety("  dami-mas ") == "DAMI_MAS")
        #expect(CollectionRun.sanitizedVariety("!!") == "TREE")
        try await withStore { store, _ in
            let run = try await store.createRun(type: .multiside, variety: "#?", block: "a1", operatorName: "",
                                                sideCount: 4, split: "field", tokenized: false)
            #expect(run.variety == "TREE")
            #expect(run.treeName(number: 1) == "TREE_A1_0001")
            await #expect(throws: StoreError.self) {
                try await store.createRun(type: .multiside, variety: "   ", block: "A1", operatorName: "",
                                          sideCount: 4, split: "field", tokenized: false)
            }
        }
    }

    @Test func weightRunsOfferTwoPhotosButLegacySingleSlotRunsStillWork() async throws {
        #expect(DatasetType.bunchWeight.sideOptions == [2])
        try await withStore { store, _ in
            let legacy = try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: "OLD", operatorName: "",
                                                   sideCount: 1, split: "field", tokenized: false)
            #expect(legacy.sideCount == 1)
            let tree = try await commit(store, legacy)
            #expect(tree.sides.count == 1)
        }
    }

    @Test func deleteRunRemovesSamplesDraftAndRunOnly() async throws {
        try await withStore { store, root in
            let doomed = try await weightRun(store, block: "A1")
            let kept = try await weightRun(store, block: "B2")
            let first = try await commit(store, doomed)
            let other = try await commit(store, kept)
            try await store.saveDraftPhoto(photo, runID: doomed.id, side: 0)

            try await store.deleteRun(id: doomed.id)
            #expect(try await store.runs(type: .bunchWeight).map(\.id) == [kept.id])
            #expect(try await store.trees(runID: doomed.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("trees/\(first.id)").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("drafts/\(doomed.id)").path))
            #expect(try await store.trees(runID: kept.id).map(\.id) == [other.id])
            #expect(try await store.draftPhotos(runID: kept.id).isEmpty)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path)
            #expect(leftovers.isEmpty)
            await #expect(throws: StoreError.self) { try await store.deleteRun(id: doomed.id) }
            // The same variety and block starts over with a new identity.
            let recreated = try await weightRun(store, block: "A1")
            #expect(recreated.nextTreeName == "DAMIMAS_A1_BW_0001")
            #expect(recreated.captureSet.captureSetId != doomed.captureSet.captureSetId)
        }
    }

    @Test func summariesCountAndSortByLastUpdate() async throws {
        try await withStore { store, _ in
            let older = try await weightRun(store, block: "A1")
            let newer = try await weightRun(store, block: "B2")
            _ = try await commit(store, older, date: Date(timeIntervalSinceNow: -100_000))
            _ = try await commit(store, older, date: Date(timeIntervalSinceNow: -90_000))
            let empty = try await weightRun(store, block: "C3")
            _ = try await commit(store, newer, date: Date(timeIntervalSinceNow: 3600))
            let summaries = try await store.summaries(type: .bunchWeight)
            #expect(zip(summaries, summaries.dropFirst()).allSatisfy { $0.updatedAt >= $1.updatedAt })
            #expect(summaries.first?.run.id == newer.id)
            let first = try #require(summaries.first { $0.run.id == older.id })
            #expect(first.treeCount == 2)
            #expect(first.photoCount == 2)
            #expect(first.completeCount == 0)
            #expect(summaries.first { $0.run.id == empty.id }?.treeCount == 0)
            // A draft or resumed run with nothing saved still has a creation-time update.
            #expect(summaries.allSatisfy { $0.updatedAt > .distantPast })
        }
    }

    @Test func exportIncludesDraftSamplesAndReportsProgress() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store)
            let tree = try await commit(store, run)
            #expect(!tree.isComplete)
            let events = Events()
            let zip = try await store.export(runID: run.id, to: root.deletingLastPathComponent(), appVersion: "test") {
                events.add($0, $1, $2)
            }
            let archive = try Archive(url: zip, accessMode: .read)
            let files = archive.filter { $0.type == .file }.map(\.path).sorted()
            #expect(files == ["capture_set.json", "images/\(tree.id)_1.jpg", "json/\(tree.id).json", "labels/\(tree.id)_1.txt",
                              "manifests/\(tree.id).json", "metadata/\(tree.id).json"])
            let seen = events.all
            let last = try #require(seen.last)
            #expect(last.0 == files.count && last.1 == files.count)
            #expect(seen.map(\.0) == seen.map(\.0).sorted())
            #expect(Set(seen.map(\.2)) == [tree.id])
        }
    }

    @Test func exportWithNothingCommittedIsEmpty() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store)
            do {
                _ = try await store.export(runID: run.id, to: root.deletingLastPathComponent(), appVersion: "test")
                Issue.record("An empty export produced an archive")
            } catch StoreError.emptyExport {
                #expect(StoreError.emptyExport.errorDescription == "Belum ada data untuk diekspor.")
            }
        }
    }

    @Test func cancellingAnExportRemovesTheWorkingFolder() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store)
            _ = try await commit(store, run)
            let folder = root.deletingLastPathComponent().appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            final class Box: @unchecked Sendable {
                private let lock = NSLock()
                private var stored: Task<URL, any Error>?
                var task: Task<URL, any Error>? {
                    get { lock.withLock { stored } }
                    set { lock.withLock { stored = newValue } }
                }
            }
            let box = Box()
            let task = Task { [store] in
                try await store.export(runID: run.id, to: folder, appVersion: "test") { _, _, _ in
                    while box.task == nil { usleep(1000) }
                    box.task?.cancel()
                }
            }
            box.task = task
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
            // The sample is untouched and a later export works.
            let zip = try await store.export(runID: run.id, to: folder, appVersion: "test")
            #expect(FileManager.default.fileExists(atPath: zip.path))
        }
    }

    @Test func manualTreeNumbersAreRejectedWhenTakenAndKeepTheCounterAhead() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store, autoId: false)
            #expect(!run.autoId)
            #expect(try await store.run(id: run.id).autoId == false)
            // Resuming keeps the setting.
            #expect(try await weightRun(store, autoId: true).autoId == false)

            let manual = try await commit(store, run, number: 7)
            #expect(manual.id == "DAMIMAS_A1_BW_0007")
            #expect(try await store.run(id: run.id).nextTreeName == "DAMIMAS_A1_BW_0008")

            let lower = try await commit(store, run, number: 3)
            #expect(lower.number == 3)
            #expect(try await store.run(id: run.id).nextTreeName == "DAMIMAS_A1_BW_0008")

            try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
            do {
                _ = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable), treeNumber: 7)
                Issue.record("A duplicate ID was accepted")
            } catch StoreError.treeExists(let name) {
                #expect(name == "DAMIMAS_A1_BW_0007")
                #expect(StoreError.treeExists(name).errorDescription?.contains("sudah ada") == true)
            }
            await #expect(throws: StoreError.self) {
                try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable), treeNumber: 0)
            }
            #expect(try await store.draftPhotos(runID: run.id).count == 1)
            #expect(try await store.trees(runID: run.id).count == 2)

            // Automatic numbering still skips taken numbers, and deleting recomputes the counter like Kotlin.
            let auto = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
            #expect(auto.number == 8)
            try await store.deleteTree(id: auto.id)
            #expect(try await store.run(id: run.id).nextTreeName == "DAMIMAS_A1_BW_0008")
            try await store.deleteTree(id: manual.id)
            #expect(try await store.run(id: run.id).nextTreeName == "DAMIMAS_A1_BW_0004")
            _ = root
        }
    }

    @Test func runsWithoutAutoIdDecodeAsAutomatic() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store)
            let file = root.appendingPathComponent("runs/\(run.id).json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(object.removeValue(forKey: "autoId") as? Bool == true)
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let reopened = try PackageStore(root: root)
            #expect(try await reopened.run(id: run.id).autoId)
            #expect(try await reopened.run(id: run.id) == run)
        }
    }

    @Test func draftSidesAreSeparateFilesAndLegacyDraftsStillRead() async throws {
        try await withStore { store, root in
            let run = try await store.createRun(type: .multiside, variety: "DAMIMAS", block: "A1", operatorName: "",
                                                sideCount: 4, split: "field", tokenized: false)
            let suggestion = Annotation(id: "det0", rect: PixelBox(x1: 1, y1: 2, x2: 30, y2: 40))
            try await store.saveDraftPhoto(CapturedPhoto(jpeg: jpeg, width: 100, height: 80, suggestions: [suggestion]),
                                           runID: run.id, side: 0)
            let draft = root.appendingPathComponent("drafts/\(run.id)")
            #expect(try Data(contentsOf: draft.appendingPathComponent("0.jpg")) == jpeg)
            let meta = try String(contentsOf: draft.appendingPathComponent("0.json"), encoding: .utf8)
            #expect(!meta.contains("jpeg"))

            // Side 1 in the legacy layout: the JPEG is embedded in the JSON.
            let legacy = CapturedPhoto(jpeg: Data([0xff, 0xd8, 0x01, 0xff, 0xd9]), width: 64, height: 48)
            try JSONEncoder().encode(legacy).write(to: draft.appendingPathComponent("1.json"))
            let reopened = try PackageStore(root: root)
            let photos = try await reopened.draftPhotos(runID: run.id)
            #expect(photos.count == 2)
            #expect(photos[0].suggestions == [suggestion] && photos[0].jpeg == jpeg && photos[0].height == 80)
            #expect(photos[1].jpeg == legacy.jpeg && photos[1].width == 64)
            // The next side continues after a legacy one, and a legacy side can be retaken.
            try await reopened.saveDraftPhoto(photo, runID: run.id, side: 2)
            let retake = CapturedPhoto(jpeg: Data([0xff, 0xd8, 0x02, 0xff, 0xd9]), width: 10, height: 10)
            try await reopened.saveDraftPhoto(retake, runID: run.id, side: 1)
            #expect(try await reopened.draftPhotos(runID: run.id).map(\.jpeg) == [jpeg, retake.jpeg, jpeg])
            await #expect(throws: StoreError.self) { try await reopened.saveDraftPhoto(photo, runID: run.id, side: 4) }
        }
    }

    @Test func updateDraftSuggestionsIsCompareAndSet() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store)
            let box = Annotation(id: "det0", rect: PixelBox(x1: 1, y1: 2, x2: 30, y2: 40))
            try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
            #expect(await store.updateDraftSuggestions(runID: run.id, side: 0, jpeg: jpeg, suggestions: [box]))
            var stored = try await store.draftPhotos(runID: run.id)
            #expect(stored[0].suggestions == [box] && stored[0].jpeg == jpeg && stored[0].width == 100)

            let retake = CapturedPhoto(jpeg: Data([0xff, 0xd8, 0x09, 0xff, 0xd9]), width: 50, height: 50)
            try await store.saveDraftPhoto(retake, runID: run.id, side: 0)
            #expect(!(await store.updateDraftSuggestions(runID: run.id, side: 0, jpeg: jpeg, suggestions: [box])))
            #expect(!(await store.updateDraftSuggestions(runID: run.id, side: 1, jpeg: retake.jpeg, suggestions: [box])))
            stored = try await store.draftPhotos(runID: run.id)
            #expect(stored[0].suggestions.isEmpty && stored[0].jpeg == retake.jpeg)

            // A legacy side is upgraded to the split layout by an update.
            let draft = root.appendingPathComponent("drafts/\(run.id)")
            try JSONEncoder().encode(photo).write(to: draft.appendingPathComponent("0.json"))
            try FileManager.default.removeItem(at: draft.appendingPathComponent("0.jpg"))
            #expect(await store.updateDraftSuggestions(runID: run.id, side: 0, jpeg: jpeg, suggestions: [box]))
            #expect(try Data(contentsOf: draft.appendingPathComponent("0.jpg")) == jpeg)
            #expect(try await store.draftPhotos(runID: run.id)[0].suggestions == [box])
        }
    }

    @Test func draftRecoveryAndInterruptedRetake() async throws {
        try await withStore { store, root in
            let run = try await weightRun(store)
            try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
            let draft = root.appendingPathComponent("drafts/\(run.id)")
            let backup = root.deletingLastPathComponent().appendingPathComponent("draft-backup")
            try FileManager.default.copyItem(at: draft, to: backup)
            _ = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
            // The app was killed after publishing but before the draft was cleared.
            try FileManager.default.moveItem(at: backup, to: draft)
            let reopened = try PackageStore(root: root)
            #expect(try await reopened.draftPhotos(runID: run.id).isEmpty)

            // A retake killed between its JPEG and metadata files leaves a side the next read drops.
            try await reopened.saveDraftPhoto(photo, runID: run.id, side: 0)
            try await reopened.saveDraftPhoto(photo, runID: run.id, side: 1)
            try Data([0xff, 0xd8, 0x07, 0xff, 0xd9]).write(to: draft.appendingPathComponent("0.jpg"))
            #expect(try await reopened.draftPhotos(runID: run.id).isEmpty)
            #expect(try await reopened.draftPhotos(runID: run.id).isEmpty)
            try await reopened.saveDraftPhoto(photo, runID: run.id, side: 0)
            #expect(try await reopened.draftPhotos(runID: run.id).count == 1)
        }
    }

    @Test func installIdentityIsExcludedFromBackup() async throws {
        try await withStore { store, root in
            let identity = root.appendingPathComponent("install-id")
            #expect(try identity.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            let token = await store.deviceToken
            // An install that predates the exclusion gains it on the next launch, keeping its value.
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            var mutable = identity
            try mutable.setResourceValues(values)
            let reopened = try PackageStore(root: root)
            #expect(await reopened.deviceToken == token)
            #expect(try identity.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }
}
