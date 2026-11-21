# Kotlin parity audit

This audit compares the v1 workflows of PalmAnnotate Kotlin with this SwiftUI port. It lists each Kotlin behavior, its Swift status, and the remaining work.

- **Kotlin reference:** [`5d671c3`](https://github.com/ULM-SawitMVC/PalmAnnotate-Kotlin/tree/5d671c30c1c17f3c7b1a40db367b74a295c82cf5). Between the previous pin `a52a5cb` and `5d671c3`, Kotlin changed only the SAF mirror, depth probing, and tree-identity checks. None of these is in v1 scope.
- **Scope:** Multisisi 4/8, Multisisi Video 4/8, Berat Tandan, and ONNX detection. Orbbec RGB-D, depth, the SAF mirror, folder resume, and external package import are out of scope.
- **Method:** a read-through of the Kotlin hub, home, session, capture, video, carousel, canvas, dedup, results, export, and domain code against the Swift sources. Each row was then checked against the code merged into `main`. Simulator and unit-test evidence is listed under [Verification](#verification).

Kotlin paths are relative to `app/src/main/java/dev/sawitulm/palmannotate/`.

## Status key

| Status | Meaning |
|---|---|
| Ported | Swift does what Kotlin does. Wording is Indonesian. |
| Improved | Swift covers Kotlin's behavior and adds safety or usability. |
| Divergent | Swift differs on purpose. The row gives the reason. |
| Partial | Some of the Kotlin behavior is missing. The row says what. |
| N/A | Out of v1 scope, or there is no iOS equivalent. |

## Summary

Of 119 rows, 88 are ported, 14 are improved, and 9 are deliberate divergences. Two are partial, all of them low-impact UI details. Six are out of scope or have no iOS equivalent. Every high and medium item from the first audit is closed. The remaining risk is hardware behavior that only a physical device can show; see [Device-only checks](#device-only-checks).

## Hub, run list, and new session

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 1 | Module hub with three workflows and the heading "Choose a data collection workflow" (`ui/home/ModuleHubScreen.kt`). | Ported | "Pilih alur pengumpulan data" section. Swift keeps a one-line description per module. |
| 2 | Version label `v{VERSION_NAME}` (`HomeScreen.kt`). | Improved | Hub footer shows version, build, and the git revision stamped at build time, which device acceptance records. |
| 3 | No settings screen; only the SAF export-folder card. | N/A | SAF is out of scope. |
| 4 | Warning that data lives only in the app until exported. | Ported | Hub footer hint: export a ZIP to move data. |
| 5 | Runs grouped by variety · block. | Divergent | One run per type, variety, and block, so a flat list is equivalent. |
| 6 | Stats card: sessions, trees or samples, groups. | Ported | Sessions, trees or samples, and photos. Groups equal sessions in Swift. |
| 7 | Empty state with icon, title, and body. | Ported | Weight lists say "Belum ada sesi berat". |
| 8 | Row text with counts and updated date, newest first. | Ported | `PackageStore.summaries(type:)` sorts by the newer of the run file and the newest sample. |
| 9 | Delete a whole run with a confirmation. | Ported | `PackageStore.deleteRun(id:)` moves the run, its samples, and its draft to a tombstone; the run file goes last so a failed delete can be retried. |
| 10 | Export ZIP per run. | Ported | "Buat ZIP" on the session screen, then the share sheet opens. |
| 11 | Export all, hidden for weight, with a sample-count confirmation. | Ported | The confirmation names the sample count. |
| 12 | Non-dismissable progress with files done, the current tree, Cancel, and the screen kept on. | Ported | `export(onProgress:)`; cancelling the task removes the partial archive. The idle timer is off while exporting. |
| 13 | "ZIP ready" feedback and the system share chooser opens on its own; empty and failed states. | Ported | The share sheet opens after the progress sheet closes. |
| 14 | ZIP contains every committed tree, draft or complete. | Ported | Drafts are exported; integrity checks unchanged. |
| 15 | ZIP layout and name `{variety}_{block}_{token}_{ts}.zip` or `PalmAnnotate_all_…`. | Ported | Swift deflates entries; Kotlin stores them. Readers accept both. |
| 16 | Artifacts rebuilt and validated before zipping. | Improved | Swift re-hashes every JPEG and the video against the stored SHA-256. |
| 17 | New-session fields with remembered last values. | Ported | Save stays disabled until the required fields are filled. |
| 18 | Reserved block tokens BW and VID rejected. | Ported | Message explains which module owns the token. |
| 19 | Photos per tree 4 or 8; weight fixed at 2 with early finish. | Ported | `DatasetType.bunchWeight.sideOptions == [2]`. Legacy one-slot weight runs still open. |
| 20 | "Automatic ID" switch; capture shows a Tree ID field and rejects an existing name. | Ported | `commitCapture(treeNumber:)`; `StoreError.treeExists`. Field prefilled with the next number, digits only. |
| 21 | Operator name optional, `UNKNOWN` when empty. | Ported | |
| 22 | Device-token naming switch, fixed once the run has started. | Ported | |
| 23 | Live name preview. | Ported | Uses the run's next number. |
| 24 | Folding into an existing run shows "continuing… next tree" as a toast. | Divergent | Shown as an alert, so the operator sees which run is reused. |
| 25 | A variety with no usable characters becomes `TREE`. | Ported | `CollectionRun.sanitizedVariety`; a blank field is still refused. |

## Session detail

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 26 | Lock badge "variety · block, locked". | Ported | |
| 27 | Stats: trees or samples, photos, next ID. | Improved | Adds complete count and operator; shows "Manual" for runs without automatic IDs. |
| 28 | Add Tree or Add Sample. | Ported | |
| 29 | Tree row with number, name, side count, draft or complete. | Ported | |
| 30 | Tap opens the carousel; a video tree opens the viewer. | Ported | |
| 31 | Delete a tree with confirmation. | Improved | Swipe and context menu; the message mentions the video. |
| 32 | After a delete, the next ID is recomputed from the surviving trees. | Ported | `deleteTree` sets `nextNumber` to the highest survivor + 1. |
| 33 | Mirror status and retry. | N/A | SAF mirror is out of scope. |

## Capture and GPS

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 34 | Camera and location permissions; denial message. | Improved | Adds an "Open Settings" action for camera, microphone, and location. |
| 35 | Header with view count, locked run, and GPS line. | Ported | `n / m foto`, lock label, GPS line. |
| 36 | GPS text: coordinates `%.5f`, stale age, location off, denied, unavailable, locating. | Ported | `CaptureLocation.describe(at:)`. |
| 37 | GPS provenance FRESH, STALE, UNAVAILABLE, PERMISSION_DENIED, LOCATION_OFF, UNKNOWN; 60 s window; re-judged at commit. | Ported | `LOCATION_OFF` comes from `locationServicesEnabled()`. |
| 38 | Re-read GPS after the permission prompt. | Ported | |
| 39 | Camera preview with a thumbnail strip and shutter. | Ported | 56 pt thumbnails. A phone in landscape shows the photo beside a scrolling control column. |
| 40 | Per-side review with a "Captured" badge, Retake, Continue. | Ported | The review pager shows a "Foto n/m" chip instead of a badge. |
| 41 | Final review pager with side chip, dots, retake. | Ported | |
| 42 | Weight: "Use 1 photo", "Take photo 2", early finish. | Ported | |
| 43 | Pre-save `QualityCheck` review. | Ported | Sheet with "Simpan tetap" and "Kembali perbaiki". |
| 44 | Commit failure text. | Ported | Fixed Indonesian message followed by the cause. |
| 45 | Draft reopen restores photos and the side, phase, and step cursor. | Partial | Photos and video are restored; the screen opens on the last photo's review rather than the stored step. |
| 46 | A draft published before cleanup is recognized. | Improved | Draft identity file. |
| 47 | Invalid-draft banner with Discard. | Ported | |
| 48 | Discard draft. | Improved | Asks first. |
| 49 | Original JPEG bytes kept when EXIF orientation is identity; otherwise re-encoded at q100. | Ported | `normalizedPhoto`. |
| 50 | Rotation applied to preview and photo outputs. | Ported | Needs a device check. |
| 51 | Detect is a manual editor action only. | Improved | Swift also detects every saved photo in the background; the next side can be taken at once, and saving waits for pending results. |
| 52 | Simulator helpers. | N/A | Debug-only photo and MP4 pickers. |

## Multisisi Video

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 53 | Record and Stop; Stop needs every side photographed. | Ported | |
| 54 | Shutter only while recording or after accept. | Ported | |
| 55 | Recording over existing photos asks "Retake all photos with the new recording?". | Ported | |
| 56 | Leaving mid-recording asks "Stop recording and discard the video?". | Ported | |
| 57 | Red dot and m:ss timer. | Ported | |
| 58 | Microphone permission with a Settings action and inline notice. | Ported | |
| 59 | Screen kept on while recording. | Ported | |
| 60 | 1080p H.264 with audio. | Ported | Passthrough remux to MP4, falling back to a re-encode. |
| 61 | Interruption discards the take with a reason. | Ported | `startVideo(onInterruption:)` ends the recording state. |
| 62 | Final review retakes a photo and keeps the video. | Ported | Unit-tested for 4 and 8 sides. |
| 63 | "This camera cannot record video and take photos together." | Ported | `CaptureError.concurrentCapture`. |
| 64 | Save returns to the tree list. | Ported | |
| 65 | Video viewer with side pager and playback. | Ported | |
| 66 | Video sidecar with filename, size, SHA-256. | Improved | Also validates audio and video tracks. |

## Annotation editor

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 67 | Opens after capture and from a tree row; title and `n/m`. | Ported | |
| 68 | Infinite looping pager; direction toggle for multiside. | Partial | Direction toggle ported; the pager stops at the first and last photo. |
| 69 | Weight photo buttons; multiside dots. | Improved | Photo buttons in both modules. |
| 70 | Back saves and completes a multiside tree, and saves a weight draft. | Ported | Custom "Kembali"; disabled while saving or detecting. |
| 71 | Review and Edit modes; Edit stops pager swipes. | Ported | |
| 72 | Pinch zoom 0.3–15×, pan. | Divergent | 1–12× with +, −, and fit buttons; no zoom below fit. |
| 73 | Draw with a minimum drag, clamped, auto-select. | Ported | |
| 74 | Move and resize with 8 handles. | Ported | |
| 75 | Hit test with a 24 dp tolerance (`BboxHitTest.pick`). | Ported | `BoxHitTest.pick`, 24 pt. |
| 76 | Ripeness class bar B1–B4, applied to the linked cluster. | Ported | |
| 77 | Delete box and its links. | Ported | |
| 78 | Link flow with hint and cancel. | Ported | |
| 79 | Link merge keeps source measurements; notice when values are replaced. | Ported | Toast above the "Tersimpan" pulse. |
| 80 | Unlink for weight. | Improved | Available in every module. |
| 81 | 16-colour link-group palette, dashed ring, coloured badge. | Ported | Group numbers follow first-link order. |
| 82 | Bunch numbering. | Divergent | Box numbers equal the exported `bunch_id` in both modules. |
| 83 | Count badge "n boxes · m unassigned · k linked". | Ported | |
| 84 | Show or hide boxes. | Ported | |
| 85 | Detect: current side, IoU > 0.5 skipped, `det` IDs, baseline seeded, leaving blocked. | Ported | `TreeDocument.mergeDetections`. |
| 86 | Dirty-tracked autosave and a "Saved" pulse. | Divergent | Swift saves after each edit through the revisioned store. |
| 87 | Inline weight panel: required weight, collapsible optional details with a filled count, Apply, opens on selection, above the keyboard. | Ported | Pinned Apply bar with a keyboard dismiss button. |
| 88 | Weight messages: required, not a number, above zero. | Ported | `Measurements.parse`. |
| 89 | Apply, link, and unlink save immediately. | Ported | |
| 90 | One completion gate for weight. | Ported | |
| 91 | "Save draft & exit" and "Save & next sample". | Ported | |
| 92 | Multiside "Save & Exit" and "Next Tree" complete the tree. | Ported | |
| 93 | Sample CSV from the editor, also for drafts; `{tree}_result.csv`. | Ported | Also `{tree}_identity.json`. |
| 94 | More menu: Dedup, Results, Depth. | Ported | Depth is out of scope. |
| 95 | Keyboard shortcut handler (never instantiated in Kotlin). | N/A | |
| 96 | LRU of 8 downsampled bitmaps. | Ported | `SideImageCache`: 2048 px, 8 entries. |

## Dedup, mismatch, and results

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 97 | Pair review with two canvases side by side. | Divergent | Each suggestion row shows crops of both bunches with score and category; linking by tapping happens on the editor canvas. |
| 98 | `SuggestionEngine` seam scoring, mutual best only. | Ported | Constants and formula match. |
| 99 | Score %, AUTO or CANDIDATE, "Accept All Auto (n)". | Ported | OTOMATIS and KANDIDAT at 0.75 and 0.50. |
| 100 | Confirmed links with remove. | Ported | |
| 101 | Clockwise and counter-clockwise toggle. | Ported | |
| 102 | Links saved. | Ported | Each accept saves at once. |
| 103 | "Bunch Class Resolution": members with side and class, majority default, apply. | Ported | Opens from Dedup "Hitung hasil", an editor banner, and Results. |
| 104 | Results: unique bunches, detections, linked duplicates, by class, by side. | Ported | |
| 105 | Results "Finish" marks complete. | Divergent | Covered by the editor's exit actions. |
| 106 | Export Output JSON, YOLO, CSV, Identity to a folder. | Ported | Results shares `{tree}.json`, `{tree}_{n}.txt`, `{tree}_result.csv`, `{tree}_identity.json`, and the annotation logs. |
| 107 | Export gate with `analyzeTree` and "Export anyway?". | Ported | |
| 108 | Export allowed for any committed tree. | Ported | |
| 109 | Identity JSON unreachable for weight in Kotlin. | Improved | Available for every module. |

## Formats, identity, detector, and platform

| # | Kotlin behavior | Status | Swift notes |
|---|---|---|---|
| 110 | Output JSON v4, YOLO, CSV, Identity, annotation log, manifest, `capture_set.json`. | Ported | Kotlin-generated fixtures for all three modules: JSON compared by structure, YOLO and CSV by bytes, manifest digests checked. |
| 111 | Install ID → device token; capture set per run. | Improved | The install ID is excluded from backups, so a restore cannot clone the token. |
| 112 | Union-find clusters in Kotlin order = `bunch_id`. | Ported | |
| 113 | Pinned model, letterbox, `createScaledBitmap` bilinear, NMS. | Ported | Scaling is byte-exact with Android. See [DETECTOR-PARITY.md](DETECTOR-PARITY.md) for the JPEG decoder result. |
| 114 | English UI. | Divergent | Indonesian UI for the field operators. |
| 115 | Toast host. | Divergent | Toasts for link notices and save pulses; alerts for errors that need acknowledgement. |
| 116 | Palm-green theme and app icon. | Ported | AccentColor and AppIcon. |
| 117 | Draft storage. | Improved | `{side}.jpg` plus metadata with the JPEG hash, written last; legacy base64 drafts still read. |
| 118 | Crash report file. | N/A | Use MetricKit or Xcode Organizer. |
| 119 | Orbbec, depth, SAF mirror, folder resume, package import. | N/A | Out of v1 scope. |

## Deliberate divergences

- **Indonesian UI (#114):** the operators read Indonesian. Kotlin's `QualityCheck` messages were already Indonesian.
- **Background detection at capture (#51):** v1 requires automatic detection. It runs after the photo is in the draft, so it never blocks capture.
- **Saving after each edit (#86):** each edit goes through `PackageStore` revisions. A crash loses at most the gesture in progress.
- **Dedup pair review (#97):** each suggestion shows crops of both bunches in a list, so every pair can be judged without paging. Tap-to-link stays on the full editor canvas.
- **Zoom range (#72):** there is no zoom below fit, because a smaller photo would only waste screen space. Buttons help one-handed field use.
- **Run grouping (#5), toasts (#24, #115), box numbering (#82), Results finish (#105):** these are presentation differences with the same data outcome.

## Remaining partial rows

All are low impact:
- #45: draft cursor restore.
- #68: wrap-around pager.

## Device-only checks

These need connected hardware and are tracked in [DESIGN.md](../DESIGN.md#device-acceptance):
- Camera permission flow, preview and saved JPEG orientation, and Display P3 photos through the detector.
- Fresh, stale, denied, and location-off GPS states.
- Concurrent photo and movie capture with audio, interruptions, auto-lock while recording, and the remuxed MP4 size.
- Share sheet, Save to Files, and export of a large dataset with the screen kept on.
- Sustained ONNX inference time per photo.

## Verification

| Check | Result |
|---|---|
| `swift test --package-path Packages/PalmCore` with `PALM_LEGACY_CORPUS` | 55 tests in 5 suites pass, including the 953-file legacy corpus and the Kotlin export fixtures. |
| iPhone 11 simulator, iOS 27.2, full UI suite | Recorded in `AGENTS.md` for each integration. |
