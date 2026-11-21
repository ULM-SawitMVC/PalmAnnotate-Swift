# Kotlin RGB export fixtures

Source revision `5d671c30c1c17f3c7b1a40db367b74a295c82cf5` in PalmAnnotate-Kotlin.

`cases.json` supplies the synthetic annotations shared by the Kotlin generator and the Swift
capture/save/export tests. The cases cover 4- and 8-side Multisisi and Multisisi Video, and
one- and two-photo Berat Tandan. The media payloads are synthetic sentinel bytes for archive
paths and hashing. They are independent of camera, audio, and media-decoding tests.

The generator compiles the pinned `ExportManager`, `YoloParser` package label writer,
`ResultsComputer`, `TreePackageManifest`, `CaptureSetDescriptor`, and ZIP path policy.
It extracts the unchanged private metadata, video metadata, and annotation-log functions
from `SessionRepository`. Small JVM adapters stand in for Android file access, URI, and
Compose color. The JVM uses the same org.json version as the Kotlin unit tests. The generator
pins wall-clock values before recording the fixtures and hashing the artifact text.

Regenerate with JDK 17, Kotlin CLI, and Python 3 from the Swift repository root.

```sh
python3 Packages/PalmCore/Tests/ExportFixtures/generate.py /path/to/PalmAnnotate-Kotlin
```

`KotlinExportTests` compares JSON structurally and YOLO and CSV as exact bytes. It checks the
committed media and all ZIP file paths, and verifies each manifest and capture descriptor
against its platform's own bytes. JSON whitespace and object key order can differ between the
two serializers, so each archive's output, metadata, revision, and manifest digests are
computed from that archive. The tests substitute Swift's run UUID and host-local capture day.

Run the suite against the optional local legacy corpus.

```sh
PALM_LEGACY_CORPUS=/path/to/Baseline-SawitMVC/ground_truth/annotations \
  swift test --package-path Packages/PalmCore
```

To retain the generated Swift ZIPs, set `PALM_EXPORT_TEST_ZIPS` to an existing empty directory
during the test. The Baseline-SawitMVC JSON readers can consume the extracted `json/` files.
