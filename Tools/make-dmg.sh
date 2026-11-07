#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
app=${1:-build/Hutchbar.app}
[[ -d "$app" ]] || { echo 'Build the app first.' >&2; exit 1; }
./Tools/verify-app.sh "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
name=$(basename "$app" .app)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"
mkdir -p dist
hdiutil create -ov -volname "$name" -srcfolder "$stage" -format UDZO "dist/$name-$version.dmg"
