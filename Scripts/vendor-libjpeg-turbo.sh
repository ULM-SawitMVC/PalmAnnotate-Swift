#!/bin/sh
set -eu

version=3.2.1
tarball_sha=c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f
url="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$version/libjpeg-turbo-$version.tar.gz"

target="$(cd "$(dirname "$0")/.." && pwd)/Packages/PalmCore/Sources/CJPEGTurbo/libjpeg-turbo"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 2 --silent --show-error "$url" --output "$work/source.tar.gz"
printf '%s  %s\n' "$tarball_sha" "$work/source.tar.gz" | shasum -a 256 -c -
tar -xzf "$work/source.tar.gz" -C "$work"
root="$work/libjpeg-turbo-$version"

rm -rf "$target"
mkdir -p "$target/src/wrapper"
cp "$root/LICENSE.md" "$root/README.ijg" "$target/"

for name in jaricom jcomapi jdapimin jdarith jdatasrc jdhuff jdinput jdlhuff jdmarker jdmaster jdphuff \
    jerror jmemmgr jmemnobs jpeg_nbits jstdhuff; do
    cp "$root/src/$name.c" "$target/src/"
done
for name in jdct jdcoefct jdhuff jdmainct jdmaster jdmerge jdsample jerror jinclude jlossls jmemsys jmorecfg \
    jpeg_nbits jpegapicomp jpegint jpeglib jsamplecomp; do
    cp "$root/src/$name.h" "$target/src/"
done

for name in jdapistd jdcolor jddiffct jdlossls jdmainct jdpostct jdsample jutils; do
    for bits in 8 12 16; do cp "$root/src/wrapper/$name-$bits.c" "$target/src/wrapper/"; done
done
for name in jdcoefct jddctmgr jdmerge jidctflt jidctfst jidctint jidctred jquant1 jquant2; do
    for bits in 8 12; do cp "$root/src/wrapper/$name-$bits.c" "$target/src/wrapper/"; done
done
for name in jdapistd jdcoefct jdcolor jddctmgr jddiffct jdlossls jdmainct jdmerge jdpostct jdsample \
    jidctflt jidctfst jidctint jidctred jquant1 jquant2 jutils; do
    cp "$root/src/$name.c" "$target/src/"
done
for name in jdcol565 jdcolext jdmrg565 jdmrgext; do cp "$root/src/$name.c" "$target/src/"; done
echo "Vendored libjpeg-turbo $version into $target"
