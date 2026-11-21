#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 SIMULATOR_UDID DIRECTORY_OF_JPEGS" >&2
    exit 2
fi
device=$1
images=$(cd "$2" && pwd)
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
./Scripts/prepare-detector.sh >&2

# Use a standalone generated project so the field harness stays out of the app build.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp project.yml "$work/production.yml"
ln -s "$repo/App" "$repo/Packages" "$repo/Vendor" "$repo/UITests" "$work/"
mkdir "$work/Photos"
for image in "$images"/*.jpg "$images"/*.jpeg "$images"/*.png; do
    [ -f "$image" ] || continue
    cp "$image" "$work/Photos/"
done
cp Scripts/DetectorParity/DetectorParityTests.swift "$work/"
cat > "$work/project.yml" <<'YAML'
include:
  - production.yml
targets:
  DetectorParityTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - DetectorParityTests.swift
      - path: Photos
        buildPhase: resources
    dependencies:
      - target: PalmAnnotate
    settings:
      GENERATE_INFOPLIST_FILE: YES
      PRODUCT_BUNDLE_IDENTIFIER: dev.sawitulm.palmannotate.detector-parity
      SWIFT_VERSION: "6.0"
schemes:
  DetectorParity:
    build:
      targets:
        PalmAnnotate: all
    test:
      targets: [DetectorParityTests]
YAML
"${XCODEGEN:-xcodegen}" generate --spec "$work/project.yml" --project "$work" >&2
if ! xcodebuild -project "$work/PalmAnnotate.xcodeproj" -scheme DetectorParity \
    -destination "platform=iOS Simulator,id=$device" -derivedDataPath "${PALM_DERIVED_DATA:-$work/DerivedData}" \
    -configuration "${PALM_CONFIGURATION:-Debug}" ENABLE_TESTABILITY=YES \
    -parallel-testing-enabled NO test >"$work/xcodebuild.log" 2>&1; then
    cat "$work/xcodebuild.log" >&2
    exit 1
fi
sed -n '/^PALM_DETECT_/p' "$work/xcodebuild.log"
