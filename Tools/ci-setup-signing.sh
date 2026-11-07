#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Called only by the protected release build; never used by local builds.
set -euo pipefail
: "${RUNNER_TEMP:?CI runner required}"
: "${GITHUB_ENV:?CI environment output required}"
: "${SIGNING_CERT_P12:?Base64 PKCS12 certificate required}"
: "${SIGNING_CERT_PASSWORD:?PKCS12 password required}"
: "${SIGNING_IDENTITY:?Developer ID Application identity required}"
work=$(mktemp -d "$RUNNER_TEMP/hutchbar-signing.XXXXXX")
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s' "$SIGNING_CERT_P12" | /usr/bin/base64 --decode > "$work/identity.p12"
keychain="$RUNNER_TEMP/hutchbar-release.keychain-db"
password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning "$keychain"
[[ "$SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || {
  echo 'Expected a Developer ID Application identity.' >&2; exit 1;
}
printf 'HUTCHBAR_SIGN_IDENTITY=%s\n' "$SIGNING_IDENTITY" >> "$GITHUB_ENV"
