#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Called only by the protected release build; never used by local builds.
set -euo pipefail
: "${RUNNER_TEMP:?CI runner required}"
: "${GITHUB_ENV:?CI environment output required}"
: "${SIGNING_CERT_P12:?Base64 PKCS12 certificate required}"
: "${SIGNING_CERT_PASSWORD:?PKCS12 password required}"
: "${SIGNING_IDENTITY:?Signing identity name required}"
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
# Self-signed identities are untrusted, so list without -v; the name must be in the imported file.
identities=$(security find-identity -p codesigning "$keychain")
printf '%s\n' "$identities"
grep -qF "\"$SIGNING_IDENTITY\"" <<< "$identities" || {
  echo 'The signing identity is not in the imported certificate.' >&2; exit 1;
}
fingerprint=$(security find-certificate -c "$SIGNING_IDENTITY" -Z "$keychain" \
  | awk '/^SHA-256 hash:/ { print tolower($3) }')
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || { echo 'Could not read the certificate fingerprint.' >&2; exit 1; }
{
  printf 'HUTCHBAR_SIGN_IDENTITY=%s\n' "$SIGNING_IDENTITY"
  printf 'SIGNING_CERT_SHA256=%s\n' "$fingerprint"
} >> "$GITHUB_ENV"
