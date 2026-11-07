#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
if [[ -z "${NOTARY_API_KEY_P8:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
  echo 'Notarization skipped: NOTARY_API_KEY_P8, NOTARY_KEY_ID and NOTARY_ISSUER_ID are required.'
  exit 0
fi
target=${1:?Usage: Tools/notarize.sh path/to/app.app-or-image.dmg}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s' "$NOTARY_API_KEY_P8" > "$work/AuthKey.p8"
submission=$target
if [[ "$target" == *.app ]]; then
  submission="$work/submission.zip"
  ditto -c -k --keepParent "$target" "$submission"
fi
xcrun notarytool submit "$submission" --wait --key "$work/AuthKey.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --output-format json > "$work/result.json"
python3 - "$work/result.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1]))['status'] != 'Accepted':
    sys.exit('Notarization was not accepted; inspect the submission in Apple notarytool.')
PY
xcrun stapler staple "$target"
xcrun stapler validate "$target"
