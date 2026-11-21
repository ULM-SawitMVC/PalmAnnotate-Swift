# PalmAnnotate Swift agent guide

This repository ports the RGB field workflows from PalmAnnotate Kotlin to native SwiftUI for iPhone. The minimum deployment target is iOS 17. The reference device is iPhone 11. iPad is not a target: do not add iPad layouts, tests, or checks. This file tracks the current port. [DESIGN.md](DESIGN.md) records the original architecture and acceptance goals. Read the implementation when a design sketch and the shipped interfaces differ.

## Sources of truth

- Start from the [pinned Kotlin source](https://github.com/ULM-SawitMVC/PalmAnnotate-Kotlin/tree/5d671c30c1c17f3c7b1a40db367b74a295c82cf5). Read its `PRODUCT.md`, `docs/TECHNICAL-CONTRACTS.md`, `docs/BUNCH-WEIGHT-MODULE.md`, and the relevant Kotlin tests and callers. Record the Android revision used for parity checks.
- Port Kotlin's intent, not its mechanics. Read the Kotlin code and tests to learn what the operator needs and which data contract holds, then build it the way an iOS app should. Match Kotlin exactly only where another program reads the result, such as export files, paths, and JSON. Do not copy workarounds for Android problems.
- `Packages/PalmCore` owns domain rules, file revisions, counting, and export formats. `App` owns SwiftUI, AVFoundation, CoreLocation, and the ONNX bridge. Keep platform-independent fixtures and assertions in PalmCore.
- The agreed v1 scope is Multisisi 4/8, Multisisi Video 4/8 with audio, Berat Tandan 1/2, and automatic ONNX detection for the annotated photo modules. Orbbec RGB-D, the depth viewer, the Android SAF mirror, and importing external Android packages are outside v1.

## Port status

Update this table when a milestone gains code or new evidence.

| Milestone | Implemented in Swift | Remaining work and exit criteria |
|---|---|---|
| M0 · Native project and navigation | XcodeGen, iPhone-only target, app icon, module hub with version and git revision, run lists with stats, sorting, and deletion, session creation, sample routes. | Install and navigate every module on a physical iPhone 11. |
| M1 · Domain and Android export parity | Domain model and Kotlin serializers. `KotlinExportTests` checks fixtures from Kotlin `5d671c3` for all modules. PalmCore reads the 953-file legacy corpus. | Rerun `Packages/PalmCore/Tests/ExportFixtures/generate.py` when Kotlin export code changes. |
| M2 · Local store, drafts, and ZIP | Atomic publication, revisions, `{side}.jpg` drafts with hashed metadata, sample and run deletion, manual tree numbers, ZIPs with drafts, export progress and cancellation. | Check the ZIP with Baseline-SawitMVC consumers. Test delete, draft recovery, share sheet, and Save to Files on device. |
| M3 · RGB photo capture and GPS | Capture, review pager, retake, invalid-draft recovery, Tree ID field, `QualityCheck` review, GPS states rechecked at commit, background detection, landscape layout. | Test permissions, orientation, Display P3 photos, and GPS states on device. |
| M4 · Annotation and measurements | Kotlin editor behaviors: Back completion, detection merge, Dedup scoring and pair crops, mismatch sheet, link colors, 24 pt hit test, inline weight panel, lazy images, per-sample exports. The pager stops at the first and last photo; the side buttons reach any photo. | Run the annotation lifecycle on a physical iPhone 11. |
| M5 · Automatic detection | Pinned model and config, ONNX Runtime CPU inference, libjpeg-turbo 3.2.1 decoding as on Android with ImageIO as fallback, Android `createScaledBitmap` scaling, and NMS. On 9 JPEGs all 62 boxes match the Android 14 emulator within 0.0003 px. `Scripts/DetectorParity` reruns the comparison and the decode check against `djpeg`. | Measure inference on a physical device. |
| M6 · Multisisi Video | Photo and movie capture with audio, passthrough MP4, stop gate, timer, idle timer, retake-all and discard confirmations, interruption handling, playback. | Test audio, concurrent stills, interruptions, playback, and ZIP on a physical device. |
| M7 · Field acceptance | Per-sample and per-session exports, data-safety hint, build revision in the hub. | Run the [device checklist](DESIGN.md#device-acceptance) per module and record device, OS, build SHA, and results. |

The last simulator verification used Xcode 27.2 and the iPhone 11 profile on iOS 27.2. Reports under `DerivedData/` are local. Physical verification requires connected hardware.

## Rules for changes

1. Preserve Output JSON v4, path and case conventions, box index references, cluster ordering, and the distinction between the manifest's RGB digest and its capture-set identity. Verify contract changes against producers and readers.
2. Keep a single completion decision for Berat Tandan. Require positive weight, preserve empty optional values, omit ripeness, and use YOLO class 0. Save Apply, link, and unlink immediately. A link preserves target measurements when the source has none.
3. Route dataset writes through `PackageStore`. Preserve atomic publication, stale-revision rejection, immutable media, and stable ZIP snapshots. Keep compression off the save path and preserve existing datasets during tests.
4. Check affected layouts on the iPhone 11 profile in portrait and landscape. Keep the active field, validation, and action reachable with the keyboard open. Test the lifecycle through creation, reopen/review, retake, draft recovery, deletion, and export where the module supports those steps.
5. Compare detector behavior with the pinned model and config. Keep captures usable for manual annotation when inference fails. Use synthetic or approved fixtures in Git. Keep field data, generated projects, downloaded detector files, build outputs, and signing material out of commits.

## Working in parallel

The simulator-verifiable parity work is integrated. The remaining rounds are device acceptance on iPhone 11 for every milestone and the gaps named in the status table. Device checks for different modules can run in parallel on separate hardware.

| Work area | Primary files | Coordinate when |
|---|---|---|
| Storage and compatibility | `Packages/PalmCore`, especially `PackageStore.swift`, `Dataset.swift`, `ExportCodec.swift`, and contract tests | A public model, completion policy, filename, or export schema needs to change. |
| Capture and hardware | `App/CaptureScreen.swift`, `App/Device/CaptureDevice.swift` | A draft/capture API, privacy description, simulator fixture, or hardware requirement changes. |
| Detector | `App/Device/Detector.swift`, `OrtBridge.*`, `YoloDetection.swift`, `Packages/PalmCore/Sources/CJPEGTurbo`, `Scripts/prepare-detector.sh` | A model/config update, build dependency, or change to the detection handoff is needed. |
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
