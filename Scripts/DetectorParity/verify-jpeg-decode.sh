#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 DIRECTORY_OF_JPEGS" >&2
    exit 2
fi
images=$(cd "$1" && pwd)
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/package/Sources/dump"
cat > "$work/package/Package.swift" <<PACKAGE
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "dump",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$repo/Packages/PalmCore")],
    targets: [.executableTarget(name: "dump", dependencies: [.product(name: "PalmCore", package: "PalmCore")])]
)
PACKAGE
cat > "$work/package/Sources/dump/main.swift" <<'SWIFT'
import Foundation
import PalmCore

let arguments = CommandLine.arguments
guard arguments.count == 3, let data = FileManager.default.contents(atPath: arguments[1]),
      let image = JPEGDecoder.decodeRGB(data) else { exit(1) }
try Data(image.pixels).write(to: URL(fileURLWithPath: arguments[2]))
print("\(image.width)x\(image.height)")
SWIFT
swift build -c release --package-path "$work/package" >&2

failed=0
for image in "$images"/*.jpg "$images"/*.jpeg; do
    [ -f "$image" ] || continue
    name=$(basename "$image")
    size=$("$work/package/.build/release/dump" "$image" "$work/ours.rgb") || { echo "REFUSED $name"; failed=1; continue; }
    djpeg -rgb -pnm "$image" > "$work/reference.ppm"
    bytes=$(wc -c < "$work/ours.rgb" | tr -d ' ')
    total=$(wc -c < "$work/reference.ppm" | tr -d ' ')
    tail -c "$bytes" "$work/reference.ppm" > "$work/reference.rgb"
    header=$((total - bytes))
    if [ "$header" -gt 0 ] && [ "$header" -lt 32 ] && cmp -s "$work/ours.rgb" "$work/reference.rgb"; then
        echo "IDENTICAL $name $size ($bytes bytes)"
    else
        echo "DIFFERENT $name $size"
        failed=1
    fi
done
exit "$failed"
