#!/bin/sh
# Assembles Ballast.app from a built binary and signs it ad hoc. Adds the iPhone tools
# from scripts/vendor-imobiledevice.sh when they've been built.
# Usage: bundle.sh <binary> <bundle path> <version>
set -eu
bin=$1; bundle=$2; version=$3
root=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin" "$bundle/Contents/MacOS/Ballast"
sed -e "s/__VERSION__/$version/g" -e "s#__REPO__#${BALLAST_REPO:-}#g" \
  "$root/Resources/Info.plist" > "$bundle/Contents/Info.plist"
if [ -f "$root/Resources/AppIcon.icns" ]; then
  cp "$root/Resources/AppIcon.icns" "$bundle/Contents/Resources/"
fi
vendor=$root/.build/vendor/imobiledevice
if [ -x "$vendor/bin/idevice_id" ]; then
  mkdir -p "$bundle/Contents/Helpers" "$bundle/Contents/Frameworks"
  cp "$vendor"/bin/* "$bundle/Contents/Helpers/"
  cp "$vendor"/lib/*.dylib "$bundle/Contents/Frameworks/"
  cp "$root/Resources/ThirdPartyNotices.txt" "$bundle/Contents/Resources/"
  # Nested code is signed from the inside out (dylibs, tools, then the app); --deep alone doesn't reliably reach it.
  for f in "$bundle"/Contents/Frameworks/* "$bundle"/Contents/Helpers/*; do codesign --force -s - "$f"; done
else
  echo "bundle.sh: no iPhone tools in this build (run scripts/vendor-imobiledevice.sh); Ballast will look for them on PATH." >&2
fi
codesign --force --deep -s - "$bundle"
echo "$bundle"
