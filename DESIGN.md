# PalmAnnotate iOS v1 - design

Native Swift + SwiftUI port of [PalmAnnotate-Kotlin](https://github.com/ULM-SawitMVC/PalmAnnotate-Kotlin).
Compatibility targets the Android RGB export contracts and the Baseline-SawitMVC readers for
the three v1 modules. The Android reference is commit
[a52a5cb](https://github.com/ULM-SawitMVC/PalmAnnotate-Kotlin/tree/a52a5cb8e0ab5d228a01a624099f1cd2182f4221).

## Scope v1

| In | Out (v1) |
|---|---|
| Module hub, Multiside 4/8 sides, Multiside video, Bunch weight | Orbbec depth, depth viewer |
| Draw/edit/class boxes, cross-side links, dedup suggestions for still-photo modules | Android SAF mirror |
| ONNX auto-detection for still-photo modules | Package import from another device |
| GPS provenance, capture-set identity, ZIP export | |

## Contracts kept byte-for-byte or schema-for-schema

Source of truth: `docs/TECHNICAL-CONTRACTS.md`, `docs/BUNCH-WEIGHT-MODULE.md`, `PRODUCT.md` in the Kotlin repo.

- Dataset layout: `images/field/{tree}_{n}.jpg`, `labels/field/{tree}_{n}.txt`, `metadata/{tree}.json`,
  `manifests/{tree}.json`, `Output JSON/{tree}.json`, `annotlog/field/{tree}_{n}.json`, `video/{tree}.mp4`.
- ZIP layout: `images/ labels/ json/ metadata/ manifests/ video/` + root `capture_set.json`.
- Output JSON v4, metadata sidecar (`artifactSchemaVersion 1`), manifest (`schemaVersion 1`), annot-log, CSV, Identity JSON.
- Tree names via `CaptureSetPolicy.treeName` (markers `BW`, `VID`, opt-in name token).
- Bunch weight: no B1-B4 anywhere in exports, YOLO class `0`, weight > 0 required, empty optional = `null`.
- `WeightDatasetPolicy.completionError` governs bunch-weight completion. The flag is derived on every save, including autosave.
- Top-level `lat`/`lng` keep any recorded coordinate; freshness lives in `gps.status`.

### Parity traps found while tracing (each gets a test)

1. **Cluster order = bunch_id.** Kotlin `UnionFind.clusters()` keeps `LinkedHashMap` insertion order of the
   surviving root, with tie rank -> `find(a)` survives, and members appended `LinkedHashSet`-style.
   Swift `Dictionary`/`Set` are unordered. `UnionFind` must be array-backed and reproduce this exactly.
2. **Coordinates are `Float` (32-bit)** in Kotlin. Use `Float`, not `Double`, or YOLO `%.6f` drifts.
3. **`%.6f` and `Double.toString`.** Verify the Swift formatter against Android golden bytes for tie cases,
   small values, and scientific notation. CSV writes `weightKg.toString()` (for example, `12.0` and `1.0E-5`).
   One `JavaFormat` file owns both.
4. **`Math.round` rounds ties toward positive infinity.** Verify pixel coordinates against Android, including ties.
5. **Real Output JSON files start with a UTF-8 BOM.** The reader strips it.
6. **`generated_at` and `savedAt` are wall-clock.** Golden comparison masks them.

## Shape A vs Shape B

**A. Port the Android stack.** SQLite (GRDB or SwiftData) as truth, files written beside it, revision journal,
mirror queue with tombstones, separate folder-resume importer. Faithful, but Android spends roughly 3.5k lines
(`SessionRepository`, `SafMirrorStore`, `FolderResumeImporter`, mirror/tombstone tables) keeping two truths in
agreement, and every one of those lines would be re-ported and re-debugged.

**B. Store versioned files in Application Support (chosen).** One `PackageStore` actor owns writes and
replays unfinished journals before opening the run index. Each tree has a private edit snapshot with exact
coordinates, stable box and link IDs, original detections, and completion state. Output JSON uses rounded
pixel coordinates and box indices, so it is a derived artifact, alongside labels and the other Android exports.
Media and app state live alongside the packages in the private store. Share completed ZIP snapshots through
the iPadOS share sheet, including Save to Files.

Keep one editable record per tree. Generate exports from the same committed revision and rebuild the tree
index from the committed snapshots at launch. Measure scan time with a field-sized dataset before adding an index cache.

## Modules

```
PalmAnnotate-Swift/
├── project.yml                  XcodeGen spec (the .xcodeproj is generated, not committed)
├── App/                         iOS app target (SwiftUI, AVFoundation, CoreLocation, ORT)
│   ├── PalmAnnotateApp.swift
│   ├── Screens/                 ModuleHub, RunList, StartRunSheet, RunDetail, CaptureFlow,
│   │                            VideoCapture, Carousel, AnnotationCanvas, MeasurementPanel, Dedup, Results
│   └── Device/                  Camera.swift, Location.swift, OrtDetector.swift
└── Packages/PalmCore/           Pure Swift package, no UIKit. `swift test` runs on the Mac.
    ├── Sources/PalmCore/
    │   ├── Model/               DatasetType, AnnotationClass, Bbox, BunchMeasurements, TreeSide,
    │   │                        CrossSideLink, TreeDocument, TreeMetadata, GpsProvenance, CaptureSetIdentity
    │   ├── Logic/               UnionFind, ResultsComputer, SuggestionEngine, TreeEdits,
    │   │                        WeightDatasetPolicy, QualityCheck, CaptureSetPolicy, GpsFreshnessPolicy
    │   ├── Codec/               JavaFormat, Yolo, OutputJSON (read+write), MetadataSidecar,
    │   │                        Manifest, AnnotLog, CSV, IdentityJSON, CaptureSetDescriptor
    │   ├── Detect/              Letterbox, YoloPostprocess (decode + class-agnostic NMS)
    │   └── Store/               PackageLayout, PackageStore, RevisionJournal, CaptureDraft, RunIndex, ZipWriter
    └── Tests/PalmCoreTests/     ported Kotlin assertions + golden round-trips
```

Everything with a contract lives in `PalmCore`, so it is tested without a simulator. `App/` holds only what needs
iOS frameworks.

## Core types (sketch)

```swift
public enum DatasetType: String, Codable, CaseIterable {
    case multiside = "MULTISIDE", bunchWeight = "BUNCH_WEIGHT", multisideVideo = "MULTISIDE_VIDEO"
    var requiresVideo: Bool { self == .multisideVideo }
    func runGroupKey(_ base: String) -> String          // multiside keeps legacy key untouched
    func allowsEarlyFinish(captured: Int, configured: Int) -> Bool
}

public enum AnnotationClass: Int, Codable { case unassigned = -1, b1 = 0, b2 = 1, b3 = 2, b4 = 3 }

public struct BoxRef: Hashable { let side: Int; let box: String }   // replaces "side:id" strings

public struct Bbox: Equatable {
    let id: String                       // "b0"...; Bbox.nextId never reuses a suffix
    var cls: AnnotationClass
    var x1, y1, x2, y2: Float
    var measurements: BunchMeasurements
}

public struct BunchMeasurements: Equatable {
    var weightKg, heightCm, circumferenceCm: Double?
    var notes: String?
    func normalized() -> Self
    var validationError: String? { get }
    static func parse(weight: String, height: String, circumference: String, notes: String) -> Result<Self, InputError>
}

public struct TreeSide: Equatable {
    let sideIndex: Int
    var imageWidth, imageHeight: Int
    var boxes: [Bbox]
    let originalBoxes: [Bbox]            // annot-log "suggestions"
    let rgbSha256: String
    let captureOrigin: CaptureOrigin     // .phoneCamera on iOS; others only when read from Android data
}

public struct CrossSideLink: Equatable { let id: String; let a: BoxRef; let b: BoxRef }  // a.side < b.side

/// Kotlin `ActiveSession`. Value type; every edit is a pure function returning a new one.
public struct TreeDocument: Equatable {
    let treeName: String
    let split: String
    let datasetType: DatasetType
    var metadata: TreeMetadata
    var sides: [TreeSide]
    var links: [CrossSideLink]
    let revision: Int
}

public struct TreeResults {
    let rawCount, linkedCount, uniqueCount, unassignedCount: Int
    let classCounts: [AnnotationClass: Int]
    let clusters: [[ClusterMember]]      // ORDERED: index + 1 == bunch_id (trap 1)
}

public enum TreeEdits {                  // Kotlin SessionUseCases
    static func addBox(_ d: TreeDocument, side: Int, rect: Rect) -> TreeDocument
    static func updateBox(_ d: TreeDocument, _ ref: BoxRef, rect: Rect) -> TreeDocument
    static func deleteBox(_ d: TreeDocument, _ ref: BoxRef) -> TreeDocument         // drops its links
    static func setClass(_ d: TreeDocument, _ ref: BoxRef, _ c: AnnotationClass) -> TreeDocument
    static func setMeasurements(_ d: TreeDocument, _ ref: BoxRef, _ m: BunchMeasurements) -> TreeDocument  // whole cluster
    static func link(_ d: TreeDocument, _ a: BoxRef, _ b: BoxRef) -> (TreeDocument, replacedMeasurements: Bool)
    static func unlink(_ d: TreeDocument, linkId: String) -> TreeDocument
    static func resolveMismatches(_ d: TreeDocument, choices: [Int: AnnotationClass]) -> TreeDocument
}
```

## Store

```swift
public actor PackageStore {
    public init(datasetRoot: URL, appStateRoot: URL) throws   // replays journals, then scans

    // runs
    func runs(_ type: DatasetType) -> [RunSummary]
    func createRun(_ request: NewRun) throws -> Run           // folds into an existing groupKey; adoption rules
    func trees(in run: Run.ID) -> [TreeSummary]

    // trees
    func load(_ treeName: String) throws -> TreeDocument
    func save(_ doc: TreeDocument, markComplete: Bool) throws -> Int        // rejects stale revision, returns new revision
    func delete(_ treeName: String) throws

    // capture
    func draft(for run: Run.ID) -> CaptureDraft?
    func putDraftSide(_ run: Run.ID, side: Int, jpeg: Data, generation: Int) throws
    func removeDraftSide(_ run: Run.ID, side: Int) throws
    func acceptDraftVideo(_ run: Run.ID, from: URL) throws
    func discardDraft(_ run: Run.ID) throws
    func commitCapture(_ run: Run.ID, gps: GpsProvenance) throws -> String  // single gate, rejects video-less MULTISIDE_VIDEO

    // export
    func exportZip(run: Run.ID?, to directory: URL) async throws -> URL
}
```

Stage the private edit snapshot and derived files, then persist the journal. Publish each file by atomic
rename and publish the manifest last. Keep the staged payload intact until the journal is cleared so recovery can
replay every step after a partial write. Use the same mechanism for first commit and deletion. Block reads and
exports for any revision that needs recovery. If a disk error prevents replay, surface the save error and keep the
pending journal available for retry.

`save` applies `WeightDatasetPolicy.resolveCompletion` to the new snapshot. For ZIP export, prepare a
stable snapshot under the store actor, then stream compression outside the write path. Hash video once when
accepting a validated draft. Measure save latency on device.

## Device layer (App/Device)

- **Camera.** One `AVCaptureSession` with `AVCapturePhotoOutput` + `AVCaptureMovieFileOutput` + audio input,
  configured once per video capture screen. Record resets previous draft photos, the shutter requires an active
  recording, and Stop requires all sides. Final review allows a photo retake. Accept a recording only after the
  operator presses Stop and the delegate confirms successful finalization. Export the temporary QuickTime file
  to a supported MP4 container with audio, then validate both tracks, stream its SHA-256, and promote it to
  `video/{tree}.mp4` at commit. Discard interrupted inputs. Normalize JPEG orientation before hashing.
  Validate simultaneous photo capture and movie recording on each supported iPad class.
  [Apple capture session setup](https://developer.apple.com/documentation/avfoundation/setting-up-a-capture-session),
  [movie output](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput),
  [asset export](https://developer.apple.com/documentation/avfoundation/avassetexportsession).
- **Location.** `CLLocationManager` -> `GpsProvenance`; freshness re-judged at commit with the same 60 s rule.
- **Detector.** Use the same `ffb-detector.onnx` and `detector.config.json` through ONNX Runtime, starting with
  CPU inference. Verify the package links on both iPadOS and the arm64 simulator before pinning its version.
  Test letterbox, tensor decoding, confidence filtering, and class-agnostic NMS in `PalmCore/Detect`.
  Detection returns unassigned suggestions for review. Compare the actual results with Android fixtures.
  [Microsoft ONNX Runtime Swift package](https://github.com/microsoft/onnxruntime-swift-package-manager).

## Golden tests

1. **Legacy reads and current export parity.** Read the 953 BOM-prefixed Output JSON v4 files in
   `Baseline-SawitMVC/ground_truth/annotations` as legacy multiside. Assert the geometry, counting, and links
   available in those fixtures. Generate separate goldens from current Kotlin for all three modules, compare
   JSON values and key presence with an injected clock, and compare YOLO and CSV bytes where applicable.
   Keep the full field corpus in the source dataset checkout.
2. **Ported Kotlin assertions.** `DomainTests`, `BunchWeightTests`, `ExportTests`, `CaptureSetIdentityTests`,
   `GpsProvenanceTests`, `MultisideVideoTests`, `ZipExporterTests`: same inputs, same expected values.
3. **Store crash tests.** Kill points between stage / journal / replace / manifest; reopen must yield either the
   old or the new revision, never a mix.
4. **Detector parity.** A few photos with Android detector output as fixtures; boxes match within 1 px.

## Delivery order (each ends verifiable)

| # | Unit | Done when |
|---|---|---|
| 0 | XcodeGen project and SwiftUI module picker | Build and launch on the iPad simulator |
| 1 | PalmCore package, models, logic, codecs | `swift test` passes golden suites 1-2 |
| 2 | PackageStore, journal, drafts, ZIP | suite 3 green; ZIP entries and checksums validate, and extracted `json/` loads with Baseline-SawitMVC |
| 3 | Module hub, run list, start-run sheet, photo capture (4/8, bunch weight 1-2), GPS | tree committed on device, reopens |
| 4 | Carousel + AnnotationCanvas + measurement panel + links + dedup review | Kotlin carousel invariants re-checked on iPad |
| 5 | ONNX detection | suite 4 green |
| 6 | Multiside video | record/stop/retake rules on device |
| 7 | Results, CSV/Identity export, Save to Files, full item-life checklist on device | CLAUDE.md rule 7 checklist passes per module |

## Device acceptance

The project targets iPadOS 17 or later in landscape. The simulator covers navigation, small fixture imports in
unit tests, and export validation. Use a physical iPad for camera and microphone permissions, simultaneous
photo and video capture, interruptions, GPS freshness, sustained detector performance, and the Files share flow.
Check the deployment target on an iPad running the oldest supported version.
