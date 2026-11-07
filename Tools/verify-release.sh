#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GITHUB_REF_NAME:?Release tag is required}"
: "${GITHUB_REPOSITORY:?Repository is required}"
if [[ ! "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  echo 'Unsupported release tag.' >&2
  exit 1
fi
commit=$(git rev-parse 'HEAD^{commit}')
remote=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_REF_NAME" --jq '.sha')
[[ "$remote" == "$commit" ]] || { echo 'Release tag moved.' >&2; exit 1; }
verified=$(gh api "repos/$GITHUB_REPOSITORY/commits/$commit" --jq '.commit.verification.verified')
[[ "$verified" == true ]] || { echo 'Release commit is not verified.' >&2; exit 1; }
relation=$(gh api "repos/$GITHUB_REPOSITORY/compare/$commit...main" --jq '.status + ":" + .merge_base_commit.sha')
[[ "$relation" == "identical:$commit" || "$relation" == "ahead:$commit" ]] || {
  echo 'Release commit is not on main.' >&2; exit 1;
}
python3 - <<'PY'
import os, pathlib, plistlib, re
version = os.environ['GITHUB_REF_NAME'][1:]
if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(alpha|beta|rc)\.(0|[1-9]\d*))?', version):
    raise SystemExit('Tag is not canonical SemVer.')
with open('Resources/Info.plist', 'rb') as stream:
    app_version = plistlib.load(stream)['CFBundleShortVersionString']
source = pathlib.Path('Sources/HutchbarCore/SessionState.swift').read_text()
core = re.search(r'public static let current = "([^"]+)"', source)
if app_version != version or not core or core[1] != version:
    raise SystemExit('Tag, plist and core versions must match.')
changelog = pathlib.Path('CHANGELOG.md').read_text()
entry = re.search(
    r'^## \[' + re.escape(version) + r'\] - \d{4}-\d{2}-\d{2}\n(.*?)(?=^## \[|\Z)',
    changelog, re.M | re.S,
)
if not entry or not entry[1].strip():
    raise SystemExit('Missing dated nonempty CHANGELOG entry.')
PY
