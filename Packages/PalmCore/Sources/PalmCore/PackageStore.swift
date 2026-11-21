import CryptoKit
import Foundation
import ZIPFoundation

public struct CapturedPhoto: Codable, Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let suggestions: [Annotation]

    public init(jpeg: Data, width: Int, height: Int, suggestions: [Annotation] = []) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.suggestions = suggestions
    }
}

/// A run with the counts and last-update time shown in the run list.
public struct RunSummary: Identifiable, Equatable, Sendable {
    public let run: CollectionRun
    public let treeCount: Int
    public let photoCount: Int
    public let completeCount: Int
    /// The newer of the run file's last write (creation, resume, or commit) and the newest tree save.
    public let updatedAt: Date
    public var id: String { run.id }
}

/// Metadata kept beside a draft photo. A legacy draft embeds the JPEG here instead of in `{side}.jpg`.
private struct DraftSide: Codable {
    var width: Int
    var height: Int
    var suggestions: [Annotation]
    var sha256: String?
    var jpeg: Data?
}

public enum StoreError: LocalizedError {
    case invalidRun, invalidCapture, videoRequired, staleRevision, missingItem, emptyExport, invalidTreeNumber
    case treeExists(String)
    case completion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRun: "Isi varietas dan blok yang valid, lalu pilih jumlah foto."
        case .invalidCapture: "Jumlah foto atau data JPEG belum valid."
        case .videoRequired: "Sampel ini membutuhkan rekaman video dengan audio."
        case .staleRevision: "Sampel sudah berubah. Buka kembali sampel untuk mengedit."
        case .missingItem: "Sesi atau sampel sudah tidak tersedia."
        case .emptyExport: "Belum ada data untuk diekspor."
        case .invalidTreeNumber: "ID harus berupa angka bulat lebih dari nol."
        case .treeExists(let name): "\(name) sudah ada. Hapus data yang ada sebelum mengambil ID yang sama lagi."
        case .completion(let reason): reason
        }
    }
}

private struct ExportArtifactError: LocalizedError {
    let filename: String

    var errorDescription: String? { "Berkas sampel hilang atau berubah: \(filename)." }
}

public actor PackageStore {
    private let root: URL
    private let installID: String
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        for directory in ["runs", "trees", "drafts", "staging"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let identity = root.appendingPathComponent("install-id")
        if FileManager.default.fileExists(atPath: identity.path) {
            installID = try String(contentsOf: identity, encoding: .utf8)
        } else {
            let value = UUID().uuidString.lowercased()
            try Data(value.utf8).write(to: identity, options: .atomic)
            installID = value
        }
        // A restored backup must not clone this device's token onto another device.
        var excluded = identity
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let staging = root.appendingPathComponent("staging")
        for item in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }

    public var deviceToken: String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return String(SHA256.hash(data: Data(installID.utf8)).prefix(6).map { alphabet[Int($0) % alphabet.count] })
    }

    public func runs(type: DatasetType) throws -> [CollectionRun] {
        try entries("runs").filter { $0.pathExtension == "json" }.map { try read(CollectionRun.self, from: $0) }
            .filter { $0.type == type }.sorted { ($0.variety, $0.block) < ($1.variety, $1.block) }
    }

    public func createRun(type: DatasetType, variety: String, block: String, operatorName: String,
                          sideCount: Int, split: String, tokenized: Bool, autoId: Bool = true) throws -> CollectionRun {
        // The form requires a variety; one without usable characters falls back to TREE as in Kotlin.
        guard !variety.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidRun }
        let variety = CollectionRun.sanitizedVariety(variety)
        let block = CollectionRun.sanitizedBlock(block)
        let operatorName = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty, !["BW", "VID"].contains(block),
              type.sideOptions.contains(sideCount) || (type == .bunchWeight && sideCount == 1),
              ["field", "train", "val", "test"].contains(split) else { throw StoreError.invalidRun }
        let id = sha256(Data("\(type.rawValue)|\(variety)|\(block)".utf8))
        let url = runURL(id)
        if fm.fileExists(atPath: url.path) {
            let original = try read(CollectionRun.self, from: url)
            var run = original
            if !operatorName.isEmpty { run.operatorName = operatorName }
            if tokenized, run.captureSet.nameToken.isEmpty, run.nextNumber == 1,
               try trees(runID: id).isEmpty, try draftPhotos(runID: id).isEmpty {
                run.captureSet.nameToken = deviceToken
            }
            if run != original { try write(run, to: url) }
            return run
        }
        let captureSet = CaptureSet(captureSetId: UUID().uuidString.lowercased(),
                                    deviceToken: deviceToken, nameToken: tokenized ? deviceToken : "")
        let run = CollectionRun(id: id, type: type, variety: variety, block: block, operatorName: operatorName,
                                sideCount: sideCount, split: split, captureSet: captureSet, autoId: autoId, nextNumber: 1)
        try write(run, to: url)
        return run
    }

    public func run(id: String) throws -> CollectionRun { try read(CollectionRun.self, from: runURL(id)) }

    /// Runs of one module with counts and last-update time, newest update first.
    public func summaries(type: DatasetType) throws -> [RunSummary] {
        let documents = try allTrees()
        return try runs(type: type).map { run in
            let own = documents.filter { $0.run.id == run.id }
            let written = (try? runURL(run.id).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return RunSummary(run: run, treeCount: own.count, photoCount: own.reduce(0) { $0 + $1.sides.count },
                              completeCount: own.filter(\.isComplete).count,
                              updatedAt: own.map(\.savedAt).reduce(written, max))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Removes the run, its samples, and its draft. The run file goes last so an interrupted delete can be retried.
    public func deleteRun(id: String) throws {
        let runFile = runURL(id)
        guard fm.fileExists(atPath: runFile.path) else { throw StoreError.missingItem }
        let tombstone = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tombstone, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tombstone) }
        for document in try allTrees() where document.run.id == id {
            try fm.moveItem(at: treeRoot(document.id), to: tombstone.appendingPathComponent("tree-" + document.id))
        }
        if fm.fileExists(atPath: draftRoot(id).path) {
            try fm.moveItem(at: draftRoot(id), to: tombstone.appendingPathComponent("draft"))
        }
        try fm.moveItem(at: runFile, to: tombstone.appendingPathComponent("run.json"))
    }

    public func trees(runID: String) throws -> [TreeDocument] {
        try allTrees().filter { $0.run.id == runID }.sorted { $0.number > $1.number }
    }

    public func tree(id: String) throws -> TreeDocument {
        try read(TreeDocument.self, from: treeRoot(id).appendingPathComponent("document.json"))
    }

    public func photoURL(treeID: String, side: Int) -> URL { treeRoot(treeID).appendingPathComponent("\(side).jpg") }
    public func videoURL(treeID: String) -> URL { treeRoot(treeID).appendingPathComponent("recording.mp4") }

    public func draftPhotos(runID: String) throws -> [CapturedPhoto] {
        try recoverDraft(runID: runID)
        let count = try draftSideCount(runID: runID)
        var photos: [CapturedPhoto] = []
        for side in 0..<count {
            guard let photo = try readDraftPhoto(runID: runID, side: side) else {
                // A retake interrupted between its two files leaves a mismatched side; the operator retakes it.
                for stale in side..<count { try? fm.removeItem(at: draftMetaURL(runID, stale)) }
                break
            }
            photos.append(photo)
        }
        return photos
    }

    public func draftVideo(runID: String) -> URL? {
        let url = draftRoot(runID).appendingPathComponent("recording.mp4")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    public func saveDraftPhoto(_ photo: CapturedPhoto, runID: String, side: Int) throws {
        let run = try run(id: runID)
        try recoverDraft(runID: runID)
        guard (0..<run.sideCount).contains(side), photo.width > 0, photo.height > 0, !photo.jpeg.isEmpty,
              side <= (try draftSideCount(runID: runID)) else { throw StoreError.invalidCapture }
        let folder = draftRoot(runID)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let identity = folder.appendingPathComponent("identity")
        if !fm.fileExists(atPath: identity.path) {
            try Data(UUID().uuidString.utf8).write(to: identity, options: .atomic)
        }
        // The metadata names the JPEG's hash and is written last, so a half-finished retake is detectable.
        try photo.jpeg.write(to: draftJPEGURL(runID, side), options: .atomic)
        try write(DraftSide(width: photo.width, height: photo.height, suggestions: photo.suggestions,
                            sha256: sha256(photo.jpeg), jpeg: nil), to: draftMetaURL(runID, side))
    }

    /// Replaces only the detector suggestions of a draft side, and only while its stored JPEG equals `jpeg`.
    public func updateDraftSuggestions(runID: String, side: Int, jpeg: Data, suggestions: [Annotation]) -> Bool {
        guard (try? recoverDraft(runID: runID)) != nil,
              var meta = try? read(DraftSide.self, from: draftMetaURL(runID, side)),
              let stored = try? storedJPEG(meta, runID: runID, side: side), stored == jpeg else { return false }
        meta.suggestions = suggestions
        meta.sha256 = sha256(stored)
        do {
            if meta.jpeg != nil {
                try stored.write(to: draftJPEGURL(runID, side), options: .atomic)
                meta.jpeg = nil
            }
            try write(meta, to: draftMetaURL(runID, side))
            return true
        } catch { return false }
    }

    public func saveDraftVideo(from source: URL, runID: String) throws {
        let run = try run(id: runID)
        guard run.type.requiresVideo, try draftSideCount(runID: runID) == run.sideCount else {
            throw StoreError.invalidCapture
        }
        let target = draftRoot(runID).appendingPathComponent("recording.mp4")
        let staging = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".incoming")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }

    public func discardDraft(runID: String) throws {
        let folder = draftRoot(runID)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
    }

    /// Publishes the draft as a sample. `treeNumber` nil numbers it automatically; a number is used as typed
    /// and must not collide with an existing sample.
    public func commitCapture(runID: String, gps: Provenance, treeNumber: Int? = nil, date: Date = .now) throws -> TreeDocument {
        var run = try run(id: runID)
        let photos = try draftPhotos(runID: runID)
        let minimum = run.type == .bunchWeight ? 1 : run.sideCount
        guard (minimum...run.sideCount).contains(photos.count) else { throw StoreError.invalidCapture }
        let videoURL = draftVideo(runID: run.id)
        if run.type.requiresVideo && videoURL == nil { throw StoreError.videoRequired }

        var number = run.nextNumber
        if let treeNumber {
            guard treeNumber >= 1 else { throw StoreError.invalidTreeNumber }
            number = treeNumber
            if fm.fileExists(atPath: treeRoot(run.treeName(number: number)).path) {
                throw StoreError.treeExists(run.treeName(number: number))
            }
        } else {
            while fm.fileExists(atPath: treeRoot(run.treeName(number: number)).path) { number += 1 }
        }
        let treeName = run.treeName(number: number)
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var video: VideoArtifact?
        if let videoURL {
            let (size, hash) = try fileDigest(videoURL)
            guard size > 0 else { throw StoreError.videoRequired }
            video = VideoArtifact(filename: treeName + ".mp4", sizeBytes: size, sha256: hash)
            try fm.copyItem(at: videoURL, to: staging.appendingPathComponent("recording.mp4"))
        }
        let sides = try photos.enumerated().map { index, photo in
            try photo.jpeg.write(to: staging.appendingPathComponent("\(index).jpg"))
            return CaptureSide(id: index, width: photo.width, height: photo.height,
                               sha256: sha256(photo.jpeg), suggestions: photo.suggestions)
        }
        let draftID = try String(contentsOf: draftRoot(runID).appendingPathComponent("identity"), encoding: .utf8)
        var document = TreeDocument(id: treeName, run: run, number: number, capturedAt: date,
                                    captureDate: ExportCodec.captureDate(date), captureDraftID: draftID,
                                    gps: gps.atCommit(date), video: video, sides: sides, savedAt: date)
        document.isComplete = run.type.requiresVideo
        try write(document, to: staging.appendingPathComponent("document.json"))

        // Reserve the number before publishing the sample. A failed publish can leave a gap.
        run.nextNumber = max(run.nextNumber, number + 1)
        try write(run, to: runURL(run.id))
        try fm.moveItem(at: staging, to: treeRoot(treeName))
        try? discardDraft(runID: runID)
        return document
    }

    public func save(_ document: TreeDocument, markComplete: Bool = false, date: Date = .now) throws -> TreeDocument {
        let previous = try tree(id: document.id)
        guard previous.revision == document.revision else { throw StoreError.staleRevision }
        let completionError = document.completionError
        if markComplete, let completionError { throw StoreError.completion(completionError) }
        var saved = document
        saved.revision += 1
        saved.savedAt = date
        saved.isComplete = document.run.type == .bunchWeight ? completionError == nil : previous.isComplete || markComplete
        try write(saved, to: treeRoot(document.id).appendingPathComponent("document.json"))
        return saved
    }

    public func deleteTree(id: String) throws {
        let target = treeRoot(id)
        guard fm.fileExists(atPath: target.path) else { throw StoreError.missingItem }
        let runID = try tree(id: id).run.id
        let tombstone = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try fm.moveItem(at: target, to: tombstone)
        try? fm.removeItem(at: tombstone)
        // Kotlin recomputes the counter from the survivors, which frees the deleted number.
        if var run = try? run(id: runID) {
            run.nextNumber = (try allTrees().filter { $0.run.id == runID }.map(\.number).max() ?? 0) + 1
            try write(run, to: runURL(runID))
        }
    }

    /// Exports every committed sample of one run, or of all runs when `runID` is nil, draft or complete.
    /// `onProgress` receives files done, files total and the sample being processed. Cancelling the calling
    /// task stops the export and removes the partial archive.
    public func export(runID: String?, to folder: URL, appVersion: String, date: Date = .now,
                       onProgress: (@Sendable (_ done: Int, _ total: Int, _ treeName: String) -> Void)? = nil) async throws -> URL {
        let documents = try allTrees().filter { runID == nil || $0.run.id == runID }
        guard !documents.isEmpty else { throw StoreError.emptyExport }
        try Task.checkCancellation()
        let working = folder.appendingPathComponent(UUID().uuidString)
        let contents = working.appendingPathComponent("dataset")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let owners: [String: String]
        do {
            owners = try prepareExport(documents, contents: contents, appVersion: appVersion, date: date, onProgress: onProgress)
        } catch {
            try? fm.removeItem(at: working)
            throw error
        }
        let first = documents[0].run
        let base = runID == nil ? "PalmAnnotate_all" : "\(first.variety)_\(first.block)"
        let target = working.appendingPathComponent("\(base)_\(deviceToken)_\(ExportCodec.archiveTimestamp(date)).zip")
        let zip = Task.detached(priority: .userInitiated) {
            let manager = FileManager()
            let archive = try Archive(url: target, accessMode: .create)
            var done = 0
            for path in try manager.subpathsOfDirectory(atPath: contents.path) {
                try Task.checkCancellation()
                try archive.addEntry(with: path, relativeTo: contents, compressionMethod: .deflate)
                if let name = owners[path] {
                    done += 1
                    onProgress?(done, owners.count, name)
                }
            }
            try manager.removeItem(at: contents)
        }
        do {
            try await withTaskCancellationHandler { try await zip.value } onCancel: { zip.cancel() }
            return target
        } catch {
            try? fm.removeItem(at: working)
            throw error
        }
    }

    /// Links the immutable media and writes the derived files. Returns each archive file's owning sample.
    private func prepareExport(_ trees: [TreeDocument], contents: URL, appVersion: String, date: Date,
                               onProgress: (@Sendable (Int, Int, String) -> Void)?) throws -> [String: String] {
        for folder in ["images", "labels", "json", "metadata", "manifests", "video"] {
            try fm.createDirectory(at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let total = trees.reduce(1) { $0 + $1.sides.count * 2 + 3 + ($1.run.type.requiresVideo ? 1 : 0) }
        var owners: [String: String] = [:]
        var entries: [[String: String]] = []
        for tree in trees.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            onProgress?(0, total, tree.id)
            let labels = tree.sides.map { ExportCodec.labels($0, type: tree.run.type) }
            let output = try ExportCodec.output(tree, generatedAt: tree.savedAt)
            let metadata = try ExportCodec.metadata(tree, generatedAt: tree.capturedAt)
            let manifest = try ExportCodec.manifest(tree, output: output, metadata: metadata, labels: labels)
            for (index, side) in tree.sides.enumerated() {
                let stem = "\(tree.id)_\(side.id + 1)"
                let image = photoURL(treeID: tree.id, side: side.id)
                let filename = stem + ".jpg"
                guard let (size, digest) = try? fileDigest(image), size > 0, digest == side.sha256.lowercased() else {
                    throw ExportArtifactError(filename: filename)
                }
                try fm.linkItem(at: image, to: contents.appendingPathComponent("images/\(filename)"))
                try labels[index].write(to: contents.appendingPathComponent("labels/\(stem).txt"))
                owners["images/\(filename)"] = tree.id
                owners["labels/\(stem).txt"] = tree.id
            }
            try output.write(to: contents.appendingPathComponent("json/\(tree.id).json"))
            try metadata.write(to: contents.appendingPathComponent("metadata/\(tree.id).json"))
            try manifest.write(to: contents.appendingPathComponent("manifests/\(tree.id).json"))
            for folder in ["json", "metadata", "manifests"] { owners["\(folder)/\(tree.id).json"] = tree.id }
            if tree.run.type.requiresVideo {
                guard let video = tree.video else { throw StoreError.videoRequired }
                let source = videoURL(treeID: tree.id)
                let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, size > 0, UInt64(size) == video.sizeBytes else {
                    throw ExportArtifactError(filename: video.filename)
                }
                try fm.linkItem(at: source, to: contents.appendingPathComponent("video/\(video.filename)"))
                owners["video/\(video.filename)"] = tree.id
            }
            entries.append(["treeName": tree.id, "captureSetId": tree.run.captureSet.captureSetId,
                            "deviceToken": tree.run.captureSet.deviceToken, "contentDigest": sha256(manifest)])
        }
        let setIDs = Set(trees.map { $0.run.captureSet.captureSetId })
        let nameTokens = Set(trees.map { $0.run.captureSet.nameToken })
        try ExportCodec.json([
            "schema": 1, "captureSetId": setIDs.count == 1 ? setIDs.first ?? "" : "",
            "deviceToken": deviceToken, "nameToken": nameTokens.count == 1 ? nameTokens.first ?? "" : "",
            "appVersion": appVersion, "generatedAt": ExportCodec.iso(date, fractionalSeconds: false), "treeCount": entries.count,
            "mergeRule": "Two packages may be extracted into one directory only when no treeName appears in " +
                "both with a different captureSetId or a different contentDigest. Compare this file, not file timestamps.",
            "trees": entries
        ]).write(to: contents.appendingPathComponent("capture_set.json"))
        owners["capture_set.json"] = entries.first?["treeName"] ?? ""
        return owners
    }

    private func draftSideCount(runID: String) throws -> Int {
        let folder = draftRoot(runID)
        guard fm.fileExists(atPath: folder.path) else { return 0 }
        let sides = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { Int($0.deletingPathExtension().lastPathComponent) }
        guard Set(sides) == Set(0..<sides.count) else { throw StoreError.invalidCapture }
        return sides.count
    }

    private func readDraftPhoto(runID: String, side: Int) throws -> CapturedPhoto? {
        let meta = try read(DraftSide.self, from: draftMetaURL(runID, side))
        guard let jpeg = try? storedJPEG(meta, runID: runID, side: side) else { return nil }
        if let expected = meta.sha256, expected != sha256(jpeg) { return nil }
        return CapturedPhoto(jpeg: jpeg, width: meta.width, height: meta.height, suggestions: meta.suggestions)
    }

    private func storedJPEG(_ meta: DraftSide, runID: String, side: Int) throws -> Data {
        try meta.jpeg ?? Data(contentsOf: draftJPEGURL(runID, side))
    }

    private func allTrees() throws -> [TreeDocument] {
        try entries("trees").map { try read(TreeDocument.self, from: $0.appendingPathComponent("document.json")) }
    }
    private func recoverDraft(runID: String) throws {
        let identity = draftRoot(runID).appendingPathComponent("identity")
        guard fm.fileExists(atPath: identity.path) else { return }
        let draftID = try String(contentsOf: identity, encoding: .utf8)
        let run = try run(id: runID)
        guard run.nextNumber > 1 else { return }
        let lastName = run.treeName(number: run.nextNumber - 1)
        if fm.fileExists(atPath: treeRoot(lastName).path), try tree(id: lastName).captureDraftID == draftID {
            try discardDraft(runID: runID)
        }
    }
    private func entries(_ name: String) throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent(name), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    }
    private func runURL(_ id: String) -> URL { root.appendingPathComponent("runs").appendingPathComponent(id + ".json") }
    private func treeRoot(_ id: String) -> URL { root.appendingPathComponent("trees").appendingPathComponent(id) }
    private func draftRoot(_ id: String) -> URL { root.appendingPathComponent("drafts").appendingPathComponent(id) }
    private func draftMetaURL(_ id: String, _ side: Int) -> URL { draftRoot(id).appendingPathComponent("\(side).json") }
    private func draftJPEGURL(_ id: String, _ side: Int) -> URL { draftRoot(id).appendingPathComponent("\(side).jpg") }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func fileDigest(_ url: URL) throws -> (UInt64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += UInt64(chunk.count)
            hash.update(data: chunk)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
