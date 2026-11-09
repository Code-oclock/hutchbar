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
kind = os.environ.get('BUILD_KIND', 'adhoc')
if kind not in ('notarized', 'self-signed', 'adhoc'):
    raise SystemExit('Unknown build kind.')
install = (
    'After verifying the download, install with Homebrew '
    '(`brew install --cask code-oclock/hutchbar/hutchbar`), click **Open Anyway** in '
    'System Settings → Privacy & Security, or run '
    '`xattr -dr com.apple.quarantine /Applications/Hutchbar.app`.'
)
if kind == 'self-signed':
    fingerprint = os.environ.get('SIGNING_CERT_SHA256', '')
    if not re.fullmatch(r'[0-9a-f]{64}', fingerprint):
        raise SystemExit('Self-signed build needs the certificate fingerprint.')
    notes += (
        '\n### Self-signed build\n\n'
        'This build is signed with the hutchbar release certificate '
        f'(SHA-256 `{fingerprint}`) and is not notarized. The stable signature lets macOS keep '
        'notification and Automation permissions across updates; it cannot prove who '
        'published the app. ' + install + '\n'
    )
elif kind == 'adhoc':
    notes += (
        '\n### Unsigned build\n\n'
        'This build is ad-hoc signed and is not notarized. ' + install + '\n'
    )
pathlib.Path('dist/release-notes.md').write_text(notes)
