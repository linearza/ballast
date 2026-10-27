#!/bin/sh
# Assembles Ballast.app from a built binary and signs it ad hoc.
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
codesign --force --deep -s - "$bundle"
echo "$bundle"
