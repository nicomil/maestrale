#!/bin/zsh
# Builds the Release app and packs it into a DMG next to a link to /Applications.
# Usage: scripts/make-dmg.sh [output-folder]   (default: build/dist)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
out="${1:-build/dist}"

xcodegen generate >/dev/null
xcodebuild -project Maestrale.xcodeproj -scheme Maestrale -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD" || true
app="build/DerivedData/Build/Products/Release/Maestrale.app"
[[ -d "$app" ]] || { echo "build failed: $app not found" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
stage=$(mktemp -d)
mkdir -p "$out"
ditto "$app" "$stage/Maestrale.app"
ln -s /Applications "$stage/Applications"
dmg="$out/Maestrale-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Maestrale $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "dmg: $dmg"
