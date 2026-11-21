#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 ANDROID_SERIAL KOTLIN_REPOSITORY DIRECTORY_OF_JPEGS" >&2
    exit 2
fi
serial=$1
scripts=$(cd "$(dirname "$0")" && pwd)
sdk=${ANDROID_HOME:-"${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"}
build_tools="$sdk/build-tools/34.0.0"
android="$sdk/platforms/android-34/android.jar"
adb="$sdk/platform-tools/adb"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 "$scripts/prepare-kotlin.py" "$2" "$work" "$3"
cp "$scripts/DetectorProbe.kt" "$scripts/AndroidDetectorInstrumentation.kt" "$work/src/test/kotlin/"
cd "$work"

maven=https://repo.maven.apache.org/maven2
curl -fsSL "$maven/com/microsoft/onnxruntime/onnxruntime-android/1.20.0/onnxruntime-android-1.20.0.aar" -o ort.aar
curl -fsSL "$maven/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.9.0/kotlinx-coroutines-core-jvm-1.9.0.jar" -o coroutines.jar
unzip -p ort.aar classes.jar > ort.jar
unzip -q ort.aar 'jni/*/*.so'
mv jni lib
cat > AndroidManifest.xml <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.sawitulm.palmannotate.detectorparity">
  <uses-sdk android:minSdkVersion="28" android:targetSdkVersion="34" />
  <application android:label="PalmAnnotate Detector Parity" android:extractNativeLibs="true" />
  <instrumentation
    android:name="dev.sawitulm.palmannotate.data.detection.AndroidDetectorInstrumentation"
    android:targetPackage="dev.sawitulm.palmannotate.detectorparity" />
</manifest>
XML

kotlinc src/test/kotlin/*.kt -classpath "$android:ort.jar:coroutines.jar" -include-runtime -d probe.jar >&2
"$build_tools/d8" --lib "$android" --min-api 28 probe.jar ort.jar coroutines.jar >&2
"$build_tools/aapt2" link -I "$android" --manifest AndroidManifest.xml -A src/main/assets -o unsigned.apk >&2
zip -q -u unsigned.apk classes*.dex
zip -q -r unsigned.apk lib
"$build_tools/zipalign" -p -f 4 unsigned.apk aligned.apk >&2
keytool -genkeypair -alias palm-parity -keyalg RSA -keystore parity.jks \
    -storepass parity-test -keypass parity-test -dname "CN=PalmAnnotate Detector Test" >&2
"$build_tools/apksigner" sign --ks parity.jks --ks-pass pass:parity-test --out detector.apk aligned.apk >&2
"$adb" -s "$serial" install detector.apk >&2
"$adb" -s "$serial" shell am instrument -w \
    dev.sawitulm.palmannotate.detectorparity/dev.sawitulm.palmannotate.data.detection.AndroidDetectorInstrumentation \
    > result.txt
"$adb" -s "$serial" uninstall dev.sawitulm.palmannotate.detectorparity >&2
if ! grep -q '^INSTRUMENTATION_CODE: -1' result.txt; then
    cat result.txt >&2
    exit 1
fi
sed -n 's/^INSTRUMENTATION_STATUS: palm=//p' result.txt
