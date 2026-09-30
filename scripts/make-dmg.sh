#!/bin/bash
# Builds build/TailCat.app, then build/TailCat-<version>.dmg (drag-to-Applications layout)
# and its .sha256. The version comes from Resources/Info.plist. Pass UNIVERSAL=1 for releases.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
DMG="build/TailCat-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
# ditto keeps the code signature and extended attributes intact.
ditto build/TailCat.app "$STAGE/TailCat.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "TailCat $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
rm -rf "$STAGE"
# Relative name inside the checksum file so `shasum -c` works next to the downloaded DMG.
(cd build && shasum -a 256 "TailCat-$VERSION.dmg" > "TailCat-$VERSION.dmg.sha256")
echo "Built $DMG"
cat "$DMG.sha256"
