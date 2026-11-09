#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Point a Homebrew cask at a published hutchbar release.

Usage: update-cask.py <cask.rb> <X.Y.Z> <sha256-of-the-zip>
Rewrites only the `version` and `sha256` lines and refuses anything unexpected.
"""
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 64
    path, version, digest = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        print("Version must be stable SemVer X.Y.Z.", file=sys.stderr)
        return 1
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        print("sha256 must be 64 lowercase hex characters.", file=sys.stderr)
        return 1
    text = path.read_text()
    text, versions = re.subn(r'(?m)^(\s*version )"[^"]*"$', rf'\1"{version}"', text)
    text, digests = re.subn(r'(?m)^(\s*sha256 )"[0-9a-f]{64}"$', rf'\1"{digest}"', text)
    if versions != 1 or digests != 1:
        print("Cask must contain exactly one version and one sha256 line.", file=sys.stderr)
        return 1
    path.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
