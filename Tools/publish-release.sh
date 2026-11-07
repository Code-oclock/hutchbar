#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
: "${EXPECTED_COMMIT:?Verified source SHA required}"
: "${PRIVATE_REPOSITORY:?Repository visibility required}"
./Tools/verify-release.sh
[[ "$(git rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] || { echo 'Unexpected source SHA.' >&2; exit 1; }
(cd dist && shasum -a 256 -c SHA256SUMS)
version=${GITHUB_REF_NAME#v}
files=("dist/Hutchbar-$version.zip" "dist/Hutchbar-$version.dmg" "dist/Hutchbar-$version.spdx.json" dist/release-notes.md dist/SHA256SUMS)
# Refuse all preexisting releases: retrying must never overwrite published bytes.
if gh release view "$GITHUB_REF_NAME" >/dev/null 2>&1; then
  echo 'Release already exists. Inspect it manually; no assets were replaced.' >&2
  exit 1
fi
args=("$GITHUB_REF_NAME" "${files[@]}" --verify-tag --title "$GITHUB_REF_NAME" --notes-file dist/release-notes.md --draft)
if [[ "$version" == *-* ]]; then args+=(--prerelease); fi
gh release create "${args[@]}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
verify_assets() {
  local count file
  count=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$GITHUB_REF_NAME" --jq '.assets | length')
  [[ "$count" == "${#files[@]}" ]] || { echo 'Unexpected release assets.' >&2; exit 1; }
  gh release download "$GITHUB_REF_NAME" --dir "$work" --clobber
  for file in "${files[@]}"; do cmp "$file" "$work/$(basename "$file")"; done
  (cd "$work" && shasum -a 256 -c SHA256SUMS)
  gh release view "$GITHUB_REF_NAME" --json body --jq '.body' > "$work/body.md"
  # gh adds one output newline; compare normalized trailing newlines only.
  python3 - "$work/body.md" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_text().rstrip('\n') != pathlib.Path('dist/release-notes.md').read_text().rstrip('\n'):
    raise SystemExit('Release notes did not match.')
PY
}
verify_assets
# Recheck the tag after upload and before making the draft visible.
./Tools/verify-release.sh
if [[ "$version" == *-* ]]; then
  gh release edit "$GITHUB_REF_NAME" --draft=false --prerelease --latest=false
else
  gh release edit "$GITHUB_REF_NAME" --draft=false --prerelease=false --latest
fi
verify_assets
immutable=false
for attempt in 1 2 3 4 5; do
  immutable=$(gh release view "$GITHUB_REF_NAME" --json isImmutable --jq '.isImmutable')
  [[ "$immutable" == true ]] && break
  sleep 1
done
if [[ "$immutable" != true ]]; then
  if [[ "$PRIVATE_REPOSITORY" == true ]]; then
    echo '::warning::Release is mutable. Enable immutable releases when opening the repository.'
  else
    echo 'Public release must be immutable; enable immutable releases in repository settings.' >&2
    exit 1
  fi
fi
