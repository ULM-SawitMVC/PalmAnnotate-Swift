# PalmAnnotate Swift agent guide

This repository ports the RGB field workflows from PalmAnnotate Kotlin to native SwiftUI for iPhone and iPad. The minimum deployment target is iOS 17. This file tracks the current port. [DESIGN.md](DESIGN.md) records the original architecture and acceptance goals. Read the implementation when a design sketch and the shipped interfaces differ.

## Sources of truth

- Start from the [pinned Kotlin source](https://github.com/ULM-SawitMVC/PalmAnnotate-Kotlin/tree/a52a5cb8e0ab5d228a01a624099f1cd2182f4221). Read its `PRODUCT.md`, `docs/TECHNICAL-CONTRACTS.md`, `docs/BUNCH-WEIGHT-MODULE.md`, and the relevant Kotlin tests and callers. Record the Android revision used for parity checks.
- `Packages/PalmCore` owns domain rules, file revisions, counting, and export formats. `App` owns SwiftUI, AVFoundation, CoreLocation, and the ONNX bridge. Keep platform-independent fixtures and assertions in PalmCore.
- The agreed v1 scope is Multisisi 4/8, Multisisi Video 4/8 with audio, Berat Tandan 1/2, and automatic ONNX detection for the annotated photo modules. Orbbec RGB-D, the depth viewer, the Android SAF mirror, and importing external Android packages are outside v1.

## Port status

Update this table when a milestone gains code or new evidence.

| Milestone | Implemented in Swift | Remaining work and exit criteria |
|---|---|---|
| M0 · Native project and navigation | XcodeGen, iPhone/iPad target, module picker, run lists, session creation, and sample routes. iPhone 11 simulator tests passed for the three module lists in portrait and landscape. | Verify the installed build on a physical iPhone and iPad. Exercise session creation and sample navigation in every module. |
| M1 · Domain and Android export parity | Dataset markers and identities, GPS provenance, stable box IDs, cross-side clusters, weight completion, and Kotlin-shaped serializers. PalmCore read all 953 local legacy JSON v4 files. | Generate fixtures from current Kotlin for all three modules. Compare JSON structures, YOLO and CSV bytes, identity/log shapes, and manifest digests. |
| M2 · Local store, drafts, and ZIP | Atomic sample publication and snapshot edits, revision conflict handling, draft recovery, sample deletion, per-session ZIP, and the capture-set descriptor. Tests cover interrupted draft cleanup and ZIP contents. | Load the exported ZIP with Baseline-SawitMVC consumers, independently verify hashes, and exercise delete, draft recovery, and Save to Files on device. The store supports exporting across runs, and the app currently exposes per-session ZIP. |
| M3 · RGB photo capture and GPS | Native photo capture, draft reopening, per-side preview/retake, 4/8 and 1/2 photo gates, and simulator photo fixtures. GPS freshness is rechecked at commit. | Port the Kotlin `QualityCheck` capture report and operator review. Validate permissions, orientation, photo review, retake, and fresh/stale/denied GPS on device. |
| M4 · Annotation and measurements | Box creation, selection, move, resize, ripeness, linked measurements, seam suggestions, mismatch resolution, and saved results. iPhone 11 tests passed for the weight editor and exports in both orientations, including the landscape keyboard. | Evaluate Kotlin's swipe carousel and pinch/pan against the Swift photo buttons and zoom control. Run the full annotation lifecycle on a phone and tablet. |
| M5 · Automatic detection | Pinned Android model and detector configuration, ONNX Runtime CPU inference, letterbox, decoding, and class-agnostic NMS. The model ran in the simulator workflow. | Compare Android and iOS detections on the same field JPEGs, with the design target of 1 px box agreement. Measure sustained inference on a physical device. |
| M6 · Multisisi Video | Simultaneous photo/movie session, audio validation, MP4 export, stop gate, final photo retake, playback, and simulator MP4 import. PalmCore rejects a video sample without a recording. For both 4 and 8 sides, a reopened draft retains its accepted video after a retake, and the committed ZIP contains the replacement photo and the original video bytes. | Test actual audio and concurrent still capture, Record/Stop gating, interruption handling, final-review retake, playback, and ZIP on a physical device. |
| M7 · Field acceptance | Per-sample CSV, Identity JSON, and annotation-log sharing. The iPhone 11 simulator used a synthetic weight sample and exercised the export controls. Six PalmCore tests passed, including the 953-file legacy corpus. | Run the [physical-device checklist](DESIGN.md#device-acceptance) per module. Record the device, OS, build SHA, and results. |

The last simulator verification used Xcode 27.2 and the iPhone 11 profile on iOS 27.2. Reports under `DerivedData/` are local. Physical verification requires connected hardware.

## Rules for changes

1. Preserve Output JSON v4, path and case conventions, box index references, cluster ordering, and the distinction between the manifest's RGB digest and its capture-set identity. Verify contract changes against producers and readers.
2. Keep a single completion decision for Berat Tandan. Require positive weight, preserve empty optional values, omit ripeness, and use YOLO class 0. Save Apply, link, and unlink immediately. A link preserves target measurements when the source has none.
3. Route dataset writes through `PackageStore`. Preserve atomic publication, stale-revision rejection, immutable media, and stable ZIP snapshots. Keep compression off the save path and preserve existing datasets during tests.
4. Check affected layouts on the iPhone 11 profile in portrait and landscape and on iPad when available. Keep the active field, validation, and action reachable with the keyboard open. Test the lifecycle through creation, reopen/review, retake, draft recovery, deletion, and export where the module supports those steps.
5. Compare detector behavior with the pinned model and config. Keep captures usable for manual annotation when inference fails. Use synthetic or approved fixtures in Git. Keep field data, generated projects, downloaded detector files, build outputs, and signing material out of commits.

## Working in parallel

Start the next round with M1 export fixtures, M3 capture QA, and M5 detector comparison. These can proceed independently until they need a shared model or fixture format. Run M6 and M7 device checks once hardware is available.

| Work area | Primary files | Coordinate when |
|---|---|---|
| Storage and compatibility | `Packages/PalmCore`, especially `PackageStore.swift`, `Dataset.swift`, `ExportCodec.swift`, and contract tests | A public model, completion policy, filename, or export schema needs to change. |
| Capture and hardware | `App/CaptureScreen.swift`, `App/Device/CaptureDevice.swift` | A draft/capture API, privacy description, simulator fixture, or hardware requirement changes. |
| Detector | `App/Device/Detector.swift`, `OrtBridge.*`, `YoloDetection.swift`, `Scripts/prepare-detector.sh` | A model/config update, build dependency, or change to the detection handoff is needed. |
| UI and verification | `App/AnnotationEditor.swift`, `CollectionScreens.swift`, `ResultsView.swift`, `UITests` | A storage interaction, common navigation route, or shared test target needs work. |

- Pick a milestone and name its owner, scope, and checks before editing shared areas. Use separate branches or worktrees from the same base for parallel changes. Assign each shared file to one owner, especially `project.yml` and `Dataset.swift`.
- Give parallel test jobs separate DerivedData paths and simulator IDs. Run install, launch, rotation, and fixture changes in sequence on any shared simulator.
- At handoff, give the branch or commit, affected files, test commands and results, and remaining checks. Integrate public API changes before the branches that depend on them. The integrator reruns affected tests and updates the table after merging.

## Verification commands

Run from the repository root.

```sh
./Scripts/prepare-detector.sh
xcodegen generate
swift test --package-path Packages/PalmCore
xcrun simctl list devices available
xcodebuild -project PalmAnnotate.xcodeproj -scheme PalmAnnotate \
  -destination "platform=iOS Simulator,id=$PALM_SIMULATOR_UDID" \
  -derivedDataPath "$PALM_DERIVED_DATA" -parallel-testing-enabled NO test
```

Set `PALM_SIMULATOR_UDID` to the target simulator ID and `PALM_DERIVED_DATA` to a writable build directory. Set `PALM_LEGACY_CORPUS` to the Baseline-SawitMVC `ground_truth/annotations` directory for the legacy corpus test. Report simulator and physical-device results explicitly.
