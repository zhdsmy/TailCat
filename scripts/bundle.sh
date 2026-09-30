#!/bin/bash
# Builds a release binary and assembles build/TailCat.app (ad-hoc signed, menu-bar only).
# UNIVERSAL=1 builds for arm64 + x86_64 (used for published releases).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
  swift build -c release "${ARCHS[@]}"
  BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/TailCat"
else
  swift build -c release
  # `--show-bin-path` goes through xcodebuild and exits until the Command Line Tools
  # license has been accepted (`sudo xcodebuild -license`). The release product is here.
  BIN=".build/release/TailCat"
fi
if [[ ! -x "$BIN" ]]; then
  echo "release binary not found at $BIN" >&2
  exit 1
fi
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCHS_BUILT="$(lipo -archs "$BIN")"
  for arch in arm64 x86_64; do
    if [[ " $ARCHS_BUILT " != *" $arch "* ]]; then
      echo "universal binary is missing $arch (has: $ARCHS_BUILT)" >&2
      exit 1
    fi
  done
fi

APP="build/TailCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TailCat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
# Finder caches icons per bundle path; a fresh mtime makes it pick up a changed AppIcon.
touch "$APP"
echo "Built $APP"
echo "Run with: open $APP"
