# Detector parity: iOS against Android

This report records whether the iOS ONNX detector returns the same boxes as the Android detector for the
same image files. Rerun it with [Scripts/DetectorParity](../Scripts/DetectorParity/README.md).

## Result

- With identical decoded pixels, iOS and Android agree on every box: the same count, a largest edge
  difference of 0.0008 px, and a largest score difference of 7e-7. This covers 9 images and 63 boxes.
- With JPEG input, iOS does not meet the 1 px target. Matched boxes differ by up to 4.8 px per edge
  (most by 0.3 to 2 px), and 3 of 9 images differ in box count. The cause is the JPEG decoder. Apple's
  decoder returns different pixel values from the libjpeg-turbo decoder that Android uses. Nothing in
  the detector code explains the remainder.
- Before this change the iOS detector was far from Android. No Android box had an iOS box within 1 px,
  and the count differed in 4 of 6 images (for example 9 against 5 and 6 against 10). The cause was how
  iOS shrank the photo. This change fixes that.

## Revisions and setup

| Item | Value |
|---|---|
| Kotlin source | `a52a5cb8e0ab5d228a01a624099f1cd2182f4221`. The checkout used for the run was at `5d671c3`. `OnnxDetector.kt` and `app/src/main/assets/models/` are identical in both. |
| Swift source | Base `eca5897` plus the commit that adds this file. |
| Model and config | `ffb-detector.onnx` and `detector.config.json` from the Kotlin revision: input 640, confidence 0.01, IoU 0.30, 300 boxes. The setup script verifies their checksums. |
| Android side | Android 14 (API 34) `default` arm64-v8a system image on the Android Emulator 37.3.10, running natively on Apple Silicon. Android ONNX Runtime 1.20.0 (the version the Kotlin app pins). The Kotlin detector, unchanged except for the two probe edits in the harness README. |
| iOS side | Xcode 27.2, iOS 27.2 simulator (iPhone 11 profile), ONNX Runtime iOS 1.20.1, CPU provider. |
| Inputs | 9 images. 6 are original field JPEGs, 3060 x 4080, 4:2:0 baseline, sRGB. 3 are resized copies of field photos made to cover other scale ratios: 1333 x 1777, 2999 x 4001 and 4624 x 3468. The images stay outside Git. |

## Cause of the original gap, and the fix

Android letterboxes with `Bitmap.createScaledBitmap(original, w, h, true)`. The iOS code drew the image
with Core Graphics, which averages many source pixels when it shrinks a 12 MP photo to 640 px. Android
takes 4 source pixels per output pixel, with no averaging. The two model inputs differed by 4.4 gray
levels on average, and the boxes moved by many pixels.

`Letterbox.scaled` and `Letterbox.tensor` in `Packages/PalmCore/Sources/PalmCore/LetterboxTensor.swift`
now reproduce the Android scaler:

- Source positions come from the inverse scale matrix, then 32.32 fixed point, less half a pixel.
- The bilinear weights keep 4 fractional bits per axis, and the blend truncates with `>> 8`.
- Positions restart from Float every 127 output pixels and step in fixed point in between.
- Taps clamp at the image edge.

I found these rules by fitting against the pixels the emulator produced, not from documentation.
The resulting scaler matches Android byte for byte:

- 0 differing samples in 9 photos at 4 different geometries (`field` photos, and the 3 resized copies),
  8.3 million samples in total.
- `LetterboxTensorTests.tensorMatchesAndroidCreateScaledBitmap` holds hashes recorded from Android for 4
  synthetic images, including a 4624 x 3468 case that fails if the 127-pixel restart changes to 128.

`App/Device/Detector.swift` also changed how it reads pixels:

- It scales the decoder's raw bytes, then converts the small image to sRGB with Core Graphics. Android
  does the same: it scales in the photo's own color space and the `Canvas` draw converts to sRGB.
  Verified on a Display P3 JPEG: Android's `getPixels` output differs from the raw bytes in 83% of
  bytes. For an sRGB photo the conversion leaves every byte unchanged.
- An image layout other than 8-bit RGB is drawn into sRGB at full size and then scaled.
- `Detector.predictions(jpeg:)` returns scores with the boxes. `detect(_:)` behaves as before.

## Results: JPEG input

Boxes are matched one to one by coordinates. "Within 1 px" counts matches with at most 1 px on every
edge. The edge columns use matches at up to 5 px, in the order x1 / y1 / x2 / y2. Times come from a
Release build on the simulator; see Speed.

| Image | Android boxes | iOS boxes | Within 1 px | Matched at 5 px | Max abs edge delta x1 / y1 / x2 / y2 (px) | Max score delta | Time (ms) |
|---|---|---|---|---|---|---|---|
| field-01 | 4 | 4 | 3 | 4 | 0.99 / 2.05 / 0.57 / 0.78 | 0.0030 | 463 |
| field-02 | 4 | 4 | 2 | 4 | 0.42 / 2.03 / 1.00 / 1.16 | 0.0039 | 487 |
| field-03 | 9 | 8 | 3 | 7 | 0.82 / 1.70 / 1.09 / 1.33 | 0.0039 | 422 |
| field-04 | 6 | 5 | 3 | 5 | 0.29 / 1.96 / 0.86 / 1.54 | 0.0021 | 403 |
| field-05 | 11 | 11 | 7 | 11 | 0.61 / 1.44 / 1.27 / 3.60 | 0.0047 | 444 |
| field-06 | 7 | 7 | 2 | 7 | 1.69 / 2.42 / 1.36 / 1.69 | 0.0042 | 397 |
| 1333 x 1777 | 9 | 9 | 6 | 8 | 0.59 / 0.88 / 0.37 / 4.83 | 0.0049 | 395 |
| 2999 x 4001 | 9 | 8 | 5 | 8 | 1.38 / 1.15 / 1.29 / 0.90 | 0.0064 | 258 |
| 4624 x 3468 | 3 | 3 | 2 | 3 | 0.72 / 1.03 / 1.00 / 0.86 | 0.0034 | 289 |
| Total | 62 | 59 | 33 | 57 | 4.83 | 0.0064 | |

Every box is class `-1` on both sides. Score order changes in 2 of 9 images (one or two boxes swap).
The 5 Android boxes without a match within 5 px all have scores between 0.0101 and 0.0115, next to the
0.01 confidence threshold. A decode change of a fraction of a gray level moves such a box across the
threshold. The score of the unmatched box in the 1333 x 1777 image is 0.0115 on both sides, so that
case is a box that moved more than 5 px, not one that crossed the threshold.

## Results: control with identical pixels

The JPEGs were decoded once with ImageIO and written as PNG. Both platforms then decoded the same PNG
bytes. The Android side ran the unchanged Kotlin detector on the PNGs. The iOS side ran the final code
in Debug.

| Image | Android boxes | iOS boxes | Within 1 px | Max abs edge delta (px) | Max score delta |
|---|---|---|---|---|---|
| field-01 | 4 | 4 | 4 | 0.0002 | 4.2e-7 |
| field-02 | 4 | 4 | 4 | 0.0002 | 1.5e-7 |
| field-03 | 8 | 8 | 8 | 0.0008 | 1.5e-7 |
| field-04 | 6 | 6 | 6 | 0.0002 | 2.4e-7 |
| field-05 | 11 | 11 | 11 | 0.0005 | 7.0e-7 |
| field-06 | 8 | 8 | 8 | 0.0007 | 4.1e-7 |
| 1333 x 1777 | 10 | 10 | 10 | 0.0002 | 1.7e-7 |
| 2999 x 4001 | 9 | 9 | 9 | 0.0005 | 3.4e-7 |
| 4624 x 3468 | 3 | 3 | 3 | 0.0004 | 1.3e-7 |

The two runtimes, the scaler, the letterbox, the output decode and NMS agree. The unchanged
`compare.py` passes this run with exit status 0.

## Residual: the JPEG decoder

- The Android decode of each of the 9 JPEGs is byte-identical to `djpeg` from libjpeg-turbo 3.2.1 with
  default settings (fancy upsampling, accurate integer IDCT).
- ImageIO's decode of the same files differs from that in 43% to 60% of bytes. The mean absolute
  difference is 0.61 to 0.89 gray levels, and the largest is 16 to 36. On field-01 the signed mean is
  about -0.5 for red and blue and +0.4 for green, which points at chroma upsampling and IDCT rounding.
- Android samples 4 source pixels per output pixel, so every decode difference reaches the model
  input without averaging. Score changes of up to 0.006 and edge shifts of up to 2 px on confident boxes
  follow from that.
- The control run removes the decoder and the difference drops to 0.0008 px. That isolates the decoder
  as the cause.

ImageIO offers no option to choose another upsampling or IDCT. Two ways to close the gap if exact JPEG
parity matters, both with a cost:

1. Decode with a libjpeg-turbo-compatible decoder in the detection path: vendor libjpeg-turbo or write
   a baseline decoder. This adds a binary dependency or a parser, and a Release device build must be
   timed.
2. Accept the residual. Boxes remain unassigned suggestions that an operator reviews. The differences
   are 0 to 5 px on 3000 px photos and affect only boxes scored within 0.002 of the threshold.

This report takes no decision between them.

## Speed

Steady-state `predictions(jpeg:)` on the iOS simulator, 3060 x 4080 JPEG, including decode, scaling,
inference and decoding of the output:

| Build | Per image | First call (creates the ONNX session) |
|---|---|---|
| Release | 397 to 487 ms | 695 ms |
| Debug | 850 to 1500 ms | 2281 ms |

The Debug figures reflect unoptimized Swift. Both runs used the Apple Silicon host CPU, not a phone.
Sustained inference on a physical device is still open and remains the M5 exit criterion for speed.

## Not verified

- Physical iPhone and iPad timing, thermal behavior and memory. A 12 MP image needs about 50 MB for the
  decoded pixels plus the scaled copies.
- A Display P3 photo from the iPhone camera. One synthetic P3 JPEG, made by converting a field photo,
  matched Android within 0.47 px with a score difference of 0.0094. The P3 conversion by Core Graphics and
  by Skia can differ by a level.
- An untagged JPEG (a quality 90 re-encode of a field photo) gave 3 of 4 boxes within 1 px. The fourth,
  scored 0.414 on Android and 0.421 on iOS, differs by 5.5 px on its right edge. That is the largest
  decoder-related edge difference seen, and the Debug build produced it.
- JPEG variants other than 4:2:0 baseline (progressive, 4:4:4, grayscale, CMYK).
- Android devices other than the emulator image. The Android scaler is the same C++ code on device, but
  this run did not exercise real hardware.
- Photos captured by the iOS app itself. All inputs were Android-origin field photos or derivatives.
