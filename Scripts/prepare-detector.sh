#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
version=1.20.1
runtime_sha=9c32108e9a1c78b090a95c2a219f244dd5f067d4caf68fb0f967103f3f20839c
model_sha=6025944212389fc4f9d0fa7659a7655592ea9d6654a2c881c0d10898154ce61c
config_sha=068338db0fe63c40be0ce7837a67f28d5889afe194e67822d9cbb1edb13c46a9
reference=a52a5cb8e0ab5d228a01a624099f1cd2182f4221
model_base="https://raw.githubusercontent.com/ULM-SawitMVC/PalmAnnotate-Kotlin/$reference/app/src/main/assets/models"

if [ -f Vendor/onnxruntime.xcframework/Info.plist ] &&
   [ -f App/DetectorAssets/ffb-detector.onnx ] && [ -f App/DetectorAssets/detector.config.json ] &&
   [ -f Vendor/ONNX-Runtime-LICENSE ] &&
   [ -f Vendor/nuget-sha ] && [ "$(cat Vendor/nuget-sha)" = "$runtime_sha" ]; then
    printf '%s  %s\n%s  %s\n' "$model_sha" App/DetectorAssets/ffb-detector.onnx \
        "$config_sha" App/DetectorAssets/detector.config.json | shasum -a 256 -c -
    exit
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 2 --silent --show-error \
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$version/microsoft.ml.onnxruntime.$version.nupkg" \
    --output "$work/runtime.nupkg"
curl --fail --location --retry 2 --silent --show-error "$model_base/ffb-detector.onnx" --output "$work/ffb-detector.onnx"
curl --fail --location --retry 2 --silent --show-error "$model_base/detector.config.json" --output "$work/detector.config.json"

printf '%s  %s\n%s  %s\n%s  %s\n' "$runtime_sha" "$work/runtime.nupkg" \
    "$model_sha" "$work/ffb-detector.onnx" "$config_sha" "$work/detector.config.json" | shasum -a 256 -c -
unzip -p "$work/runtime.nupkg" runtimes/ios/native/onnxruntime.xcframework.zip > "$work/ios.zip"
unzip -q "$work/ios.zip" -d "$work"
unzip -p "$work/runtime.nupkg" LICENSE > "$work/ONNX-Runtime-LICENSE"
mkdir -p Vendor App/DetectorAssets
rm -rf Vendor/onnxruntime.xcframework
mv "$work/onnxruntime.xcframework" Vendor/
mv "$work/ONNX-Runtime-LICENSE" Vendor/
mv "$work/ffb-detector.onnx" "$work/detector.config.json" App/DetectorAssets/
printf '%s\n' "$runtime_sha" > Vendor/nuget-sha
