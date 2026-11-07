#!/bin/bash
set -eu
cd "$(dirname "$0")"
app="build/Dude, Where’s My Disk.app"
cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-build.XXXXXXXX")"
trap 'rm -rf "$cache_dir"' EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$cache_dir" \
    Sources/*.swift -o "$app/Contents/MacOS/DudeWheresMyDisk"
cp Resources/Info.plist "$app/Contents/"
cp Resources/Disk.icns Resources/*Buddy*.gif "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
