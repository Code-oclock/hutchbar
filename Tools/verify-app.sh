#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep diagnostic entitlements out of every distributable bundle; allow only the reviewed set.
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
# Exactly the entitlements the app needs; anything else (notably
# com.apple.security.get-task-allow) must never ship.
allowed = {'com.apple.security.automation.apple-events': True}
unexpected = {k: v for k, v in entitlements.items() if allowed.get(k) != v}
if unexpected:
    raise SystemExit('Distribution bundle has unexpected entitlements: ' + ', '.join(sorted(unexpected)))
PY
codesign -dvv "$app" 2> "$work/signature.txt"
grep -Eq 'flags=.*\([^)]*runtime[),]' "$work/signature.txt" || {
  echo 'Distribution bundle is missing hardened runtime.' >&2; exit 1;
}
