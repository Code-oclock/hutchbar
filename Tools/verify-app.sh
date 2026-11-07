#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep diagnostic entitlements out of every distributable bundle.
set -euo pipefail
app=${1:?Usage: Tools/verify-app.sh path/to/Hutchbar.app}
codesign --verify --strict "$app"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null
python3 - "$work/entitlements.plist" <<'PY'
import pathlib, plistlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
entitlements = plistlib.loads(raw) if raw.strip() else {}
if entitlements:
    raise SystemExit('Distribution bundle must have empty entitlements; diagnostic access must not ship.')
PY
codesign -dvv "$app" 2> "$work/signature.txt"
grep -Eq 'flags=.*\([^)]*runtime[),]' "$work/signature.txt" || {
  echo 'Distribution bundle is missing hardened runtime.' >&2; exit 1;
}
