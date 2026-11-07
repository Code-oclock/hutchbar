#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract one exact Keep a Changelog entry; never evaluate its contents."""
import os
import pathlib
import re

version = os.environ['GITHUB_REF_NAME'][1:]
text = pathlib.Path('CHANGELOG.md').read_text()
entry = re.search(
    r'^## \[' + re.escape(version) + r'\] - \d{4}-\d{2}-\d{2}\n(.*?)(?=^## \[|\Z)',
    text, re.M | re.S,
)
if not entry or not entry[1].strip():
    raise SystemExit('Missing or empty release notes.')
notes = entry[1].strip() + '\n'
if os.environ.get('SIGNED_BUILD') != 'true':
    notes += (
        '\n### Unsigned build\n\n'
        'This build is ad-hoc signed and is not notarized. After verifying the download, '
        'run `xattr -dr com.apple.quarantine /Applications/Hutchbar.app`.\n'
    )
pathlib.Path('dist/release-notes.md').write_text(notes)
