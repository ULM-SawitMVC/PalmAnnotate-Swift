#!/bin/sh
# Prints the Android bitmap-scaling hashes that PalmCore's LetterboxTensorTests expect.
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 ANDROID_SERIAL" >&2
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
cd "$work"

cat > AndroidManifest.xml <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.sawitulm.palmannotate.scalinggolden">
  <uses-sdk android:minSdkVersion="28" android:targetSdkVersion="34" />
  <application android:label="PalmAnnotate Scaling Golden" />
  <instrumentation
    android:name="dev.sawitulm.palmannotate.scalinggolden.AndroidScalingGolden"
    android:targetPackage="dev.sawitulm.palmannotate.scalinggolden" />
</manifest>
XML
kotlinc "$scripts/AndroidScalingGolden.kt" -classpath "$android" -include-runtime -d golden.jar >&2
"$build_tools/d8" --lib "$android" --min-api 28 golden.jar >&2
"$build_tools/aapt2" link -I "$android" --manifest AndroidManifest.xml -o unsigned.apk >&2
zip -q -u unsigned.apk classes*.dex
"$build_tools/zipalign" -p -f 4 unsigned.apk aligned.apk >&2
keytool -genkeypair -alias palm-golden -keyalg RSA -keystore golden.jks \
    -storepass golden-test -keypass golden-test -dname "CN=PalmAnnotate Scaling Golden" >&2
"$build_tools/apksigner" sign --ks golden.jks --ks-pass pass:golden-test --out golden.apk aligned.apk >&2
"$adb" -s "$serial" install golden.apk >&2
"$adb" -s "$serial" shell am instrument -w \
    dev.sawitulm.palmannotate.scalinggolden/dev.sawitulm.palmannotate.scalinggolden.AndroidScalingGolden \
    > result.txt
"$adb" -s "$serial" uninstall dev.sawitulm.palmannotate.scalinggolden >&2
if ! grep -q '^INSTRUMENTATION_CODE: -1' result.txt; then
    cat result.txt >&2
    exit 1
fi
sed -n 's/^INSTRUMENTATION_STATUS: palm=//p' result.txt
