# Detector parity

These scripts run the pinned Android detector and the iOS detector on the same images, then compare the
boxes. The results and their analysis are in [docs/DETECTOR-PARITY.md](../../docs/DETECTOR-PARITY.md).

Use approved inputs. Keep the image directory, the reports, and the Android SDK outside Git.

## What each side runs

| Side | What runs | Source |
|---|---|---|
| Android | `OnnxDetector.kt` and its domain classes, unmodified except for two edits. One records each score as the box is returned. The other turns the detector's log-and-return-empty error paths into exceptions, so a failure cannot pass as "no boxes". It runs as a scratch instrumentation APK on an Android 14 arm64 emulator with Android ONNX Runtime 1.20.0, the version the Kotlin app pins. | Kotlin revision `a52a5cb8e0ab5d228a01a624099f1cd2182f4221` read with `git show`. `OnnxDetector.kt` and the model files are identical at `5d671c3`. |
| iOS | The app's `Detector` actor in a generated unit-test bundle on an iOS simulator, with ONNX Runtime iOS 1.20.1 and the app's model. The test hands the file bytes to `Detector.predictions(jpeg:)`. | This repository. |

## Requirements

- macOS with Xcode, XcodeGen, JDK 17, `kotlinc`, `python3`, `git`, `zip`, `curl`.
- An Android SDK with `platforms;android-34`, `build-tools;34.0.0`, `platform-tools`, `emulator` and
  `system-images;android-34;default;arm64-v8a`. Point `ANDROID_HOME` at it.
- A checkout of the Kotlin repository that contains the pinned revision. The scripts only read it.
- A directory of RGB JPEGs, or lossless PNGs for the control run below.

## Procedure

1. Start the emulator, or any Android 14 device, and wait for it to boot.

   ```sh
   export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
   export PATH="$JAVA_HOME/bin:$PATH"
   "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -no-window -no-audio -no-snapshot -gpu swiftshader_indirect &
   "$ANDROID_HOME/platform-tools/adb" wait-for-device
   ```

   If `avdmanager` cannot create the AVD from an unpacked SDK, write `$ANDROID_AVD_HOME/$AVD.ini` and
   `$ANDROID_AVD_HOME/$AVD.avd/config.ini` by hand. Set `image.sysdir.1`, `hw.cpu.arch=arm64` and
   `abi.type=arm64-v8a`.

2. Run the Android probe. The first run downloads ONNX Runtime and the coroutines JAR from Maven.

   ```sh
   Scripts/DetectorParity/run-android.sh "$ANDROID_SERIAL" "$KOTLIN_REPO" "$IMAGE_DIR" > android.txt
   ```

3. Run the iOS probe on your own simulator with its own DerivedData path.

   ```sh
   export PALM_DERIVED_DATA=/tmp/palm-dd-detector
   Scripts/DetectorParity/run-ios.sh "$PALM_SIMULATOR_UDID" "$IMAGE_DIR" > ios.txt
   PALM_CONFIGURATION=Release Scripts/DetectorParity/run-ios.sh "$PALM_SIMULATOR_UDID" "$IMAGE_DIR" > ios-release.txt
   ```

   Debug is the default. Only the Release run says anything useful about speed. `PALM_DETECT_COLD_MS`
   in the report includes creating the ONNX session, and each `PALM_DETECT_MS` is one steady-state
   call that includes JPEG decode.

4. Compare.

   ```sh
   python3 Scripts/DetectorParity/compare.py android.txt ios.txt                  # pass/fail at 1 px
   python3 Scripts/DetectorParity/compare.py --tolerance 5 android.txt ios.txt    # measure the misses
   ```

   The comparator requires the same images, the same box count, class `-1` everywhere, and a one-to-one
   match with at most 1 original-image pixel of error on every edge. Boxes match by coordinates, because
   a small score change can reorder them. It also reports the largest score difference and the number of
   rank changes.

5. Shut down the emulator (`adb emu kill`) and delete any simulator you created.

## Control run: identical pixels

Android decodes JPEGs with libjpeg-turbo and iOS decodes them with Apple's decoder. The two decoders do
not produce the same pixels, which is the one remaining source of difference between the platforms. To
show that everything after the decoder agrees, convert the JPEGs to PNG with ImageIO, then run steps 2
to 4 on the PNG directory. Both platforms decode a PNG to the same bytes, so the boxes should agree to
well under a pixel. `docs/DETECTOR-PARITY.md` has the results.

## Scaling golden

`run-android-scaling-golden.sh "$ANDROID_SERIAL"` scales four synthetic images with the call the
detector uses and prints a hash of each result. `LetterboxTensorTests` in PalmCore holds those hashes.
Rerun the script and update the test only if the pinned Android detector or the target Android image
changes.

## Files

| File | Purpose |
|---|---|
| `run-android.sh`, `prepare-kotlin.py`, `DetectorProbe.kt`, `AndroidDetectorInstrumentation.kt` | Build and run the Android probe. |
| `run-ios.sh`, `DetectorParityTests.swift` | Generate a standalone test project and run the iOS probe. |
| `compare.py` | Compare the two reports. |
| `run-android-scaling-golden.sh`, `AndroidScalingGolden.kt` | Record Android bitmap-scaling hashes for PalmCore tests. |
